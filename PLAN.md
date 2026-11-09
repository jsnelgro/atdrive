# ATDrive plan

A Dropbox/Google Drive–style drive backed by **atproto spaces**. **Swift only**: one SwiftPM
package with one core module that every target builds on.

## Why Swift

| Platform | How a "cloud drive" plugs into the OS | Implication |
|---|---|---|
| iOS | A File Provider extension. **It's the only option** | Swift |
| macOS | File Provider (Dropbox, Google Drive and OneDrive all use it). FUSE needs a third-party install | Swift |
| Linux | **No File Provider–like API exists.** The standard approach is a FUSE mount (e.g. `rclone mount`) or a synced folder | Swift on Linux works for the CLI. FUSE needs a small libfuse wrapper |

Rust only reaches iOS and macOS through a Swift layer, which means two languages. Swift covers
all three platforms and is memory-safe by default (Swift 6 adds data-race checking).

## Status

- [x] **Phase 1, CLI (macOS + Linux):** `login`, `logout`, `whoami`, `ls`, `tree`, `put`, `get`,
  `cat`, `mkdir`, `mv`, `rm`.
  - Unit tests pass on Linux and macOS (CI).
  - Used against the live alpha PDS: OAuth sign-in, `ls`, `cat`, `put`.
  - Remote machines sign in by pasting the browser's redirect address. The flow has been tested
    up to the browser approval; a full remote sign-in is still to be tried.
- [x] **Phase 2, macOS File Provider:** a menu-bar host app plus an
  `NSFileProviderReplicatedExtension`, assembled by `scripts/build-app.sh` without an .xcodeproj.
  - **Verified on a real Mac against the alpha PDS:**
    - OAuth sign-in from the menu bar, and enabling the drive in Finder (the first-run prompt).
    - Uploading by drag-and-drop.
    - Re-downloading after "Remove Download".
    - A file `put` from the CLI appearing in Finder.
    - Apple Development signing works; no provisioning profile needed.
  - **How it works:** the sync anchor is the repo revision (`getLatestCommit`), and changes are
    found by diffing tree snapshots held in memory. Changes made here are settled against the
    drive with `ConflictRules` (shared with `atdrive sync`; see "Conflict rules" below), using the
    base version macOS passes with each change. `Item`'s metadata version records the folder and
    name for that. `DriveIndex` remembers what this Mac has seen of the drive, for deleted
    folders, and re-reports items a delete kept so macOS puts them back.
  - **Not yet exercised:** rename, move and delete from Finder; conflicted copies; large files.
    Of the conflict rules, on a real Mac: deletes that keep an edit (do kept items come back in
    Finder?), the drive's move winning (does Finder move the item back?), and a name clash
    renaming the new item.
  - **Next:**
    - Persist snapshots across extension restarts.
    - Push instead of polling.
    - Upload/download progress in Finder.
    - Show "click Enable in Finder" in the menu until the drive is enabled.
- [x] **Phase 3, Linux: a synced folder,** `atdrive sync [~/atdrive]` (plus `--install` for a
  systemd user service). Chosen over a FUSE mount because it works on any server (no root,
  `/dev/fuse` or libfuse), keeps working offline, and every program sees ordinary files.
  - **Tested** with unit tests against `FakePDS` and real folders: first-sync merges, edits,
    moves and deletes in both directions, conflicts, interrupted passes, and the inotify watcher.
  - **Not yet exercised:** against the live alpha PDS, and under systemd on a real server.
  - **How it works:** see *Folder sync* below.
  - **Later:** a FUSE mount, for drives too big to keep a full copy of (files fetched on demand).
- [ ] **Phase 4, iOS:** the same extension code with an iOS host app.
- [ ] **Storage v2** (see *Storage v2* below): incremental sync, transferring only changed chunks,
  versions and trash, client-side encryption.
- [ ] **Later:**
  - Publish the lexicons and narrow the OAuth scope (see below).
  - Shared folders (`memberspace`).

## Folder sync

`FolderSync` (in `Sources/ATDriveCore/Sync/`) runs in passes: on a local change (inotify), and
every 30 seconds to check the drive (`getLatestCommit`; the tree is listed only when the revision
moved).

- **Three-way merge, by node ID.** `.atdrive/state.json` in the folder records what the last pass
  left in agreement: each node's parent, name, hash, and the local file's `lstat`. Each side is
  compared with it, so "deleted here" and "new on the drive" can be told apart. Local items keep
  their node ID by path, then by inode (renames and moves, including whole folders), then by hash
  (copied and deleted, e.g. across disks). Files are read only when their `lstat` changed.
- **Rules** (`SyncPlan`): the per-item decisions come from `ConflictRules`, shared with the Mac
  app (see "Conflict rules" below). Across items, it keeps folders that something kept is in, and
  gives each name in a folder to one item. A first sync is just this, starting from an empty
  state.
- **Applying** (`SyncRun`): local moves go through `.atdrive/staging` (with a journal, so a killed
  pass is recovered), so swaps and moves into new folders work. Then the drive is updated, then
  files are downloaded to `.atdrive/downloads` and renamed into place. Nothing local is
  overwritten or deleted if its `lstat` changed since the folder was listed; it's left for the next
  pass. Only items that got all the way through are saved as agreed, so an interrupted pass picks
  up where it left off (and an interrupted conflict doesn't make two copies).
- **Guards:** it stops if the folder or `.atdrive` disappears, refuses a folder synced with
  another account, and takes a lock so only one sync runs per folder. Files changed in the last
  couple of seconds wait (they may still be being written).

## Conflict rules

`ConflictRules` (`Sources/ATDriveCore/ConflictRules.swift`) is the one place that decides what
happens when something changed in two places. The README's "Conflicts" section says it for users.

| | `atdrive sync` (`SyncPlan`) | Mac app (File Provider extension) |
|---|---|---|
| Base version | `.atdrive/state.json` | The `NSFileProviderItemVersion` macOS passes with each change: content version = SHA-256; metadata version records the folder and name |
| Edited on both sides | `contents` | `modifyItem` |
| Moved on both sides | `location` | `modifyItem` |
| Deleted here, edited there | `deleteStands` | `deleteItem` (the kept file is re-reported so macOS puts it back) |
| Edited here, deleted there | `deleteStands` | `modifyItem` writes it back under its own ID |
| Folder deleted, changed inside | Folders kept if needed by what's kept | `keptWhenDeleting`, against what this Mac has seen (`DriveIndex`) |
| Something added to a folder deleted there | The folder is kept | `folderID` puts the folder back |
| Name clash | Newcomer renamed; identical ones paired | `createItem` / `modifyItem` rename the newcomer, or pair identical items macOS doesn't already have |

`ConflictRulesAgreeWithSyncTests` runs a deleted-folder case through `atdrive sync` and checks it
keeps exactly what `keptWhenDeleting` keeps.

## Data model

- **One drive = one space:** `at://<did>/space/me.jsnelgro.atdrive.drive/default`, under the
  `personalspace` policy. It's created on the first write.
- **One record per file or folder:** `me.jsnelgro.atdrive.node`. The rkey is a TID and is
  permanent. Fields:
  - `parent`: rkey, absent for the top level
  - `name`, `kind`, `createdAt`
  - files only: `size`, `sha256`, `modifiedAt`, `chunks: [blob]`
- **File contents:** 4 MiB chunks, uploaded with `com.atproto.repo.uploadBlob` and read back with
  `com.atproto.space.getBlob`. Every chunk is verified against its CID, and the whole file
  against its SHA-256.
- **Damaged trees:** a node whose parent was deleted, and a cycle created by concurrent moves,
  are both shown at the top level, so nothing is ever hidden.

## Storage v2 (planned)

Goals: fetch only what changed, upload only what changed, keep old versions and deleted files for
a while, and keep file contents and names unreadable to whoever runs the PDS. Four steps, each
useful on its own, in this order.

### What shapes the design

Checked against the reference branch at `704b9e2` (2026-11-05):

- **A blob lives only while a record references it.** The PDS can't see links inside blobs, so
  blobs that point to other blobs (how IPFS stores big files) would be garbage-collected. Every
  link to a blob has to be in a record, and records are capped at 1 MiB.
- **No compare-and-swap,** so there can't be one "root of the drive" that every device updates
  (as in Dolt or git): two devices would overwrite each other. One record per file stays.
  - There is create-if-absent: `createRecord` and `applyWrites#create` fail with
    `RecordAlreadyExists`.
  - Updates and deletes of a missing record fail with `RecordNotFound`.
  - `applyWrites` is one transaction of up to 200 writes.
- **There's a change feed:** `com.atproto.space.listRepoOps(since:)` returns every write after a
  revision, with the record values. It isn't history: the server may compact it.
- **A space's commit is a set hash** (LtHash over the repo's records), not a Merkle tree. There's
  no tree to walk to find what changed; the change feed does that.
- **Blobs are content-addressed** (CID = SHA-256 of the bytes), so identical chunks are stored once.
- **Self-hosted PDSes default to a 5 MB blob limit,** so chunks stay at most 4 MiB.

**Not doing:**
- **A DHT:** handle → DID → PDS already says where everything is.
- **Erasure coding:** one PDS is one point of failure, and shards on it protect nothing.
- **A Dolt-style versioned tree with one root:** it needs compare-and-swap.
- **Per-device logs (Hypercore):** the change feed plus `ConflictRules` already cover it.

### Step 1: incremental sync

- **First, records we can't read must not look like deletions.**
  - Today `Drive.tree()` drops them and `SyncPlan` treats them as deleted on the drive. A client
    older than a format change would then delete its local copies.
  - `tree()` should return them as unknown. Sync and the Mac extension should leave those IDs alone
    and say an update is needed.
  - This must ship, and be installed everywhere, before any format change (steps 3 and 4).
- **Applying changes:**
  - `Spaces.swift` gets `listRepoOps`. `Drive.changes(since:)` turns ops into node upserts and
    deletes, and `DriveTree` applies them.
  - `FolderSync` and `DriveIndex` keep the tree and its revision, and apply changes instead of
    listing everything. A poll becomes one request, which returns nothing when nothing changed. It
    replaces `getLatestCommit`.
- **Gaps:**
  - Each op's `prev` must equal the CID we hold for that record (none for a create). A mismatch, an
    error, or no saved revision means a full listing, as today.
  - Checking our records against the commit's LtHash would catch everything. It needs BLAKE3,
    which swift-crypto lacks: later, if at all.
- Persisting the tree also covers the Mac's "persist snapshots across extension restarts".

### Step 2: transfer only changed chunks

There's no format change: a file is still an ordered list of blobs, so older clients read it.

- **Content-defined chunking (FastCDC):**
  - Boundaries follow the content, so an insert near the start changes one or two chunks instead of
    every chunk after it.
  - Min 256 KiB, average 1 MiB, max 4 MiB.
- **Skip chunks the drive already has.** The tree lists every chunk's CID, and a chunk whose CID is
  already there isn't uploaded. Copying a file within the drive uploads nothing.
- **Download only missing chunks.**
  - Re-chunk the local copy of the previous version (the synced file, or what the Mac has on disk),
    and reuse chunks whose CIDs match. Fetch the rest.
  - The local file is the cache.
- **Parallel transfers:** a few chunks at a time.
  - Chunks never change, and writing the node record is what makes the new contents current. An
    interrupted upload leaves the old version in place.
- **Bigger files:** smaller chunks mean more of them per record (about 9 GB per record at a
  1 MiB average). Past that, the chunk list continues in `me.jsnelgro.atdrive.chunks` records,
  written in the same `applyWrites`.

### Step 3: versions and trash

- **A version is an old chunk list.**
  - Replacing a file writes two records in one `applyWrites`: the updated node, and a
    `me.jsnelgro.atdrive.version` record with the old contents.
  - The version record holds node ID, name and parent at the time, size, sha256, chunks,
    `modifiedAt` and device.
  - The version record keeps the old chunks alive. With step 2, a version costs only the chunks
    that changed.
- **Trash:**
  - Deleting moves the record to `me.jsnelgro.atdrive.trash` with the same rkey, plus `trashedAt`
    (a delete and a create in one `applyWrites`).
  - Folders move with everything inside them, deepest first in batches of 200, like deletes today.
  - Older clients list only `node`, so to them it's an ordinary delete.
  - Restoring is the reverse move. It also brings back the folders the item was in, if they're in
    the trash, and otherwise puts it at the top level.
- **Pruning:**
  - Keep versions and trash for 30 days, and always each file's latest few versions.
  - Any device may prune during a sync pass. If another device already deleted a record, the batch
    fails with `RecordNotFound`; retry without that record.
  - Deleting a version record lets the PDS delete chunks nothing else uses.
- `ConflictRules` doesn't change. Versions are a second safety net.
- Add the new collections to `lexicons/`, to `drive.json`'s `collections`, and to the narrow OAuth
  scope.

### Step 4: encryption

- **On or off per drive:**
  - A drive is encrypted if `me.jsnelgro.atdrive.keyring` (rkey `self`) exists.
  - `atdrive encrypt` converts a drive: it re-uploads every file, rewrites every record, and drops
    old plaintext versions and trash (otherwise they'd keep exposing the plaintext).
  - Spaces' access control still applies. Encryption protects against the PDS operator.
- **Records** (`node`, `version`, `trash`):
  - Only what the PDS needs stays readable: `chunks` (so blobs are kept) and a key ID.
  - Everything else, `parent` included, is `sealed`: AES-GCM under a key derived from the drive
    key. The collection and rkey are associated data, so the PDS can't swap records between files.
  - The plaintext `sha256` must go: it would let the server confirm you hold a known file.
- **Chunks: keyed convergent encryption,** as in Tahoe-LAFS and borg:
  - A chunk's ID is HMAC(drive key, plaintext), and its key is derived from that ID. Each key
    encrypts exactly one plaintext, so AES-GCM can use a fixed nonce.
  - Identical chunks encrypt to identical bytes, so step 2's skipping still works. Without the
    drive key, the server can't test for known files.
  - The chunker is seeded from the drive key, so chunk sizes don't fingerprint files.
  - Chunk IDs go in the sealed metadata. Sharing a folder later can hand over those, not the
    drive key.
- **The rest of the code doesn't change.** `NodeRecord` stays the in-memory type, and sealing is a
  layer between `Drive` and `Spaces`. `SyncPlan`, `ConflictRules` and the extension compare
  hashes after decryption.
- **What the server still sees:**
  - How many records there are.
  - Chunk counts and sizes (so roughly file sizes).
  - Creation times (TIDs), and when writes happen.
  - Which chunks are shared between files.
  - A malicious PDS can drop or roll back records, but can't read or forge them.
- **Keys:**
  - **The drive key** is 32 random bytes.
  - **Each device has its own key pair** (Curve25519), stored where its session is.
  - **The keyring** holds the drive key wrapped for each device's public key, and once more for a
    recovery key.
  - **The recovery key** is 256 random bits, shown once as words to write down. It's high-entropy,
    so it needs no password KDF (swift-crypto has no Argon2).
  - **Adding a device:** `atdrive login`, then one of:
    - `atdrive unlock` with the recovery key.
    - Approve it from a device that has the key. The new device posts its public key and shows a
      short code, and approving checks the same code, so the PDS can't slip in a key of its own.
  - **Removing a device:**
    - Remove its entry, and start a new drive key for new writes.
    - The keyring keeps the old keys, wrapped by the new one, for reading.
    - What the removed device already had stays readable to it.
  - Losing every device and the recovery key loses the data. The app and the CLI say so when
    encryption is turned on.

### CLI

| Command | What it does |
|---|---|
| `versions <path>` | A file's versions: when, size, which device |
| `get` / `cat <path>@<when>` | A file as it was: `@-1` (the previous version), `@2026-11-08`, `@<version ID>` |
| `restore <path>@<when>` | Make an old version current. It becomes a new version, so it can be undone |
| `trash` | What's in the trash |
| `trash restore <path>…` | Bring things back |
| `trash empty [--older-than 7d]` | Delete them for good |
| `rm --permanent` | Delete without the trash (plain `rm` moves things to the trash) |
| `du` | Space used: current files, versions, trash, and what they share |
| `prune [--keep 30d]` | Apply the retention policy now |
| `encrypt` | Convert the drive to encrypted |
| `devices` | The devices that hold the drive key |
| `devices approve <code>` / `devices remove <name>` | Add or remove one |
| `unlock` / `recovery-key` | Set up this device with the recovery key / make a new recovery key |

On the Mac, trash and versions start in a menu-bar window. Whether Finder can show server-side
versions is an open question.

### Tests

- **`FakePDS` gains:**
  - `listRepoOps`, with compaction, to test gaps.
  - Create-if-absent, and `RecordNotFound` in `applyWrites`.
  - Blob garbage collection: a blob disappears once nothing references it, so a version that
    doesn't keep its chunks fails a test.
- **Chunking** gets fixed test vectors, so every platform cuts the same boundaries.
- **The format guard** gets a test: a record from a newer format must not delete a local file.

### Open questions

- **What versions record:** only content changes (as above), or renames and moves too? Moves would
  let the whole drive be viewed as of a date (`atdrive ls /@2026-11-01`), but need a record per
  write.
- **Retention:** the defaults, and whether every device prunes or only one.
- **Encryption:** encrypted-only drives, or plaintext stays an option?
- **Create-if-absent:** is it reliable under concurrent writes on the live PDS?

## Protocol notes (alpha, as of 2026-11-05)

- **Reference implementation:** `bluesky-social/atproto`, branch `permissioned-data-alpha`.
  Bluesky updates the hosted PDS on Thursdays.
- **Limits:**
  - Records: at most 1 MiB.
  - `applyWrites`: at most 200 writes.
  - Blobs: the hosted alpha advertises a 300 MB limit, while the PDS default is 5 MB.
- **Auth and privacy:**
  - **OAuth is how you sign in.** It's implemented here: PAR + PKCE + DPoP, a loopback client
    ID, and a redirect to 127.0.0.1. App-password sessions still work, for scripts.
  - **Naming a space type in a scope** (`space:me.jsnelgro.atdrive.drive?…`) makes the PDS
    resolve that type's lexicon for the consent screen. If the lexicon can't be resolved, the
    sign-in fails with `invalid_scope: Unable to retrieve space declarations`.
  - **So ATDrive asks for `space:*`** (reads of your own spaces) until its lexicons are published:
    1. Add a DNS TXT record `_lexicon.atdrive.jsnelgro.me` → `did=<publishing account DID>`.
    2. Publish `com.atproto.lexicon.schema` records for `me.jsnelgro.atdrive.drive` and `.node`.
    3. Switch `OAuthLogin.scope` to `narrowScope`.
  - **Public OAuth clients get two-week sessions** on Bluesky's PDS, so you sign in again after
    that.
  - Spaces are **not** end-to-end encrypted.
- **No compare-and-swap** on space writes, so conflict detection has to happen on the client.
  Creates do fail if the record exists (`RecordAlreadyExists`).
- **Change feed:** `listRepoOps(since:)` lists writes after a revision. See *Storage v2*.

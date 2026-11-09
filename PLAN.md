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
- [ ] **Storage v2** (see *Storage v2* below): incremental sync, an encrypted-only drive,
  transferring only changed chunks, and 30 days of history (edits, renames, moves, deletes).
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

Goals:
- Fetch only what changed, and upload only what changed.
- Keep 30 days of history: edits, renames, moves and deletes. The trash is part of it.
- Keep file contents and names unreadable to whoever runs the PDS. Drives are encrypted only.

There are no users yet, so none of this is backward compatible. The format changes in place, and
existing test drives are wiped, not migrated. Four steps, in this order.

### What shapes the design

Checked against the reference branch at `704b9e2` (2026-11-05):

- **A blob lives only while a record references it.** The PDS can't see links inside blobs, so
  blobs that point to other blobs (how IPFS stores big files) would be garbage-collected. Every
  link to a blob has to be in a record, and records are capped at 1 MiB.
- **No compare-and-swap,** so there can't be one "root of the drive" that every device updates
  (as in Dolt or git): two devices would overwrite each other. One record per file stays, and
  anything several devices write gets one record per writer.
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

- **Sync must never mistake "can't see it" for "deleted".** Today two things look like deletions
  to `SyncPlan`, so it would delete local copies:
  - A record this device can't read: `Drive.tree()` drops it. After step 2, that includes a record
    sealed with a key this device doesn't have yet.
  - A drive that's gone, say because the alpha PDS was wiped: on `SpaceNotFound`, `tree()` returns
    an empty drive. The local folder may then be the only copy left.
- **The fix:**
  - `tree()` returns unreadable records as unknown. Sync and the Mac extension leave those IDs
    alone and say why.
  - A missing drive that this device has synced before stops sync, as a missing folder does.
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

### Step 2: encryption

Drives are encrypted only. Spaces' access control still applies; encryption protects against the
PDS operator.

- **Records** (`node`, plus `chunks` and `change` from steps 3 and 4):
  - Only what the PDS needs stays readable: `chunks` (so blobs are kept) and a key ID.
  - Everything else, `parent` included, is `sealed`: AES-GCM under a key derived from the drive
    key. The collection and rkey are associated data, so the PDS can't swap records between files.
  - There's no plaintext `sha256`: it would let the server confirm you hold a known file.
- **Chunks: keyed convergent encryption,** as in Tahoe-LAFS and borg:
  - A chunk's ID is HMAC(drive key, plaintext), and its key is derived from that ID. Each key
    encrypts exactly one plaintext, so AES-GCM can use a fixed nonce.
  - Identical chunks encrypt to identical bytes, so they're stored once and step 3 can skip them.
    Without the drive key, the server can't test for known files.
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
  - **The drive key** is 32 random bytes, made when the drive is created.
  - **Each device has its own key pair** (Curve25519), stored where its session is.
  - **One record per device** (`me.jsnelgro.atdrive.device`) holds the drive key wrapped for that
    device's public key. One more (rkey `recovery`) wraps it for the recovery key. They're separate
    records because two devices editing one shared keyring record would overwrite each other.
  - **The recovery key** is 256 random bits, shown once as words to write down when the drive is
    created. It's high-entropy, so it needs no password KDF (swift-crypto has no Argon2).
  - **Adding a device:** `atdrive login`, then one of:
    - `atdrive unlock` with the recovery key.
    - Approve it from a device that has the key. The new device posts its public key and shows a
      short code, and approving checks the same code, so the PDS can't slip in a key of its own.
  - **Removing a device:**
    - Delete its record, and start a new drive key for new writes, wrapped for the remaining
      devices.
    - Old keys are kept, wrapped by the new one, to read older records.
    - What the removed device already had stays readable to it.
  - Losing every device and the recovery key loses the data. Creating the drive says so, next to
    the recovery key.

### Step 3: transfer only changed chunks

- **Content-defined chunking (FastCDC):**
  - Boundaries follow the content, so an insert near the start changes one or two chunks instead of
    every chunk after it.
  - Min 256 KiB, average 1 MiB, max 4 MiB.
  - The chunker is seeded from the drive key, so chunk sizes don't fingerprint files.
- **Skip chunks the drive already has.** The tree lists every chunk's CID, and an encrypted chunk
  whose CID is already there isn't uploaded. Copying a file within the drive uploads nothing.
- **Download only missing chunks.**
  - Re-chunk the local copy of the previous version (the synced file, or what the Mac has on disk).
    Reuse chunks whose IDs match the file's sealed chunk IDs, and fetch the rest.
  - The local file is the cache.
- **Parallel transfers:** a few chunks at a time.
  - Chunks never change, and writing the node record is what makes the new contents current. An
    interrupted upload leaves the old version in place.
- **Bigger files:** smaller chunks mean more of them per record (about 6 GB per record at a
  1 MiB average, with chunk IDs). Past that, the chunk list continues in
  `me.jsnelgro.atdrive.chunks` records, written in the same `applyWrites`.

### Step 4: history

Thirty days of every change: edits, renames, moves and deletes.

- **One change record per write.**
  - Every write to a node also writes a `me.jsnelgro.atdrive.change` record, in the same
    `applyWrites`.
  - Its rkey is a TID (when). It holds the node's ID, the kind of change (created, edited, renamed,
    moved, deleted, restored), the device, and the node's state just before the change.
- **What a change record holds:**
  - Always the node's name and parent before the change.
  - Its contents (size, sha256, chunks) only when the change replaced or removed them, that is,
    edits and deletes. Renames and moves don't copy the chunk list.
  - A create holds "didn't exist".
  - The change record keeps the old chunks alive. With step 3, an edit's history costs only the
    chunks that changed.
- **The drive as of a time T** in the last 30 days:
  - Take every node that exists now or appears in a change.
  - For each one, the earliest change after T gives its name and parent at T, or says it didn't
    exist yet. No change after T means it's as it is now.
  - Its contents at T come from the earliest change after T that holds contents, or are the
    current ones.
  - Changes older than 30 days are never needed for this, so pruning is just deleting them.
- **Trash** is the deletes of the last 30 days: nodes whose latest change is a delete.
  - Restoring one creates the node again under its own ID, from that change's state (a create, so
    it fails if the node is already back). It also writes a "restored" change.
  - It brings back the folders it was in, if they were deleted too.
- **Folders:** deleting a folder deletes, and records, everything in it. That's one node delete and
  one change per item, deepest first, 100 items per `applyWrites`.
- **Pruning:**
  - Changes older than the retention are deleted. The retention (30 days) is in the drive's
    `me.jsnelgro.atdrive.settings` record (rkey `self`), so every device agrees.
  - Any device may prune during a sync pass. If another device already deleted a change, the batch
    fails with `RecordNotFound`; retry without it.
  - Deleting changes lets the PDS delete chunks nothing else uses.
- **Purging** deletes a file or folder and all of its history now, for things that mustn't stay
  around.
- **Caveats:**
  - Times come from the writing device's clock.
  - Two devices changing the same file at once each record their own "before". The history stays
    readable, and the current state is settled by `ConflictRules` as today.
- **`ConflictRules` doesn't change.** History is a second safety net: a move that lost, or what a
  folder delete took with it, can be put back.
- **Lexicons:** add `chunks`, `change`, `device` and `settings` to `lexicons/`, to `drive.json`'s
  `collections`, and to the narrow OAuth scope.

### CLI

| Command | What it does |
|---|---|
| `history [path]` | Changes to a file, or to a folder and everything in it (the whole drive without a path): when, what, which device |
| `ls` / `tree` / `get` / `cat <path>@<when>` | The drive as it was. `<when>` is `-1` (before the latest change), `-2h` (two hours ago), `2026-11-08`, `2026-11-08T14:00`, or a change ID. The path is looked up as of then, so something moved since is found under its old path |
| `restore <path>@<when>` | Put a file or folder back as it was: contents, name and place. For a folder, everything in it too. It's recorded as new changes, so it can be undone |
| `trash` | What was deleted in the last 30 days |
| `trash restore <path>…` | Bring things back where they were |
| `purge <path>…` | Delete now, with all history |
| `trash empty` | Purge everything in the trash |
| `du` | Space used by current files and by history, and what they share |
| `prune` | Apply the retention now |
| `devices` | The devices that hold the drive key |
| `devices approve <code>` / `devices remove <name>` | Add or remove one |
| `unlock` / `recovery-key` | Set up this device with the recovery key / make a new recovery key |

On the Mac, trash and history start in a menu-bar window. Whether Finder can show history is an
open question.

### Tests

- **`FakePDS` gains:**
  - `listRepoOps`, with compaction, to test gaps.
  - Create-if-absent, and `RecordNotFound` in `applyWrites`.
  - Blob garbage collection: a blob disappears once nothing references it, so history that doesn't
    keep its chunks fails a test.
  - A way to wipe the space, for the missing-drive guard.
- **Chunking** gets fixed test vectors, so every platform cuts the same boundaries.
- **The guards** get tests: a record this device can't read, and a drive that's gone, must not
  delete local files.
- **History** gets a replay test:
  - Run random edits, renames, moves, deletes and restores, snapshotting the tree as they go.
  - Check that the drive rebuilt for each snapshot's time matches the snapshot, before and after
    pruning.

### Open questions

- **Create-if-absent:** is it reliable under concurrent writes on the live PDS?
- **Finder:** can it show history (File Provider has no obvious API for server-side versions)?

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

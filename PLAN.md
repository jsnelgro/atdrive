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
- [ ] **Storage v2** (see *Storage v2* below): incremental sync; 30 days of history (edits,
  renames, moves, deletes) that also stops races from losing edits; an encrypted-only drive; and
  transferring only changed chunks.
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
- Never lose an edit to two devices writing at once.
- Keep file contents and names unreadable to whoever runs the PDS. Drives are encrypted only.

There are no users yet, so none of this is backward compatible. The format changes in place, and
existing test drives are wiped, not migrated. Four steps, in this order.

### What shapes the design

Checked against the reference branch at `704b9e2` (2026-11-05):

- **A blob lives only while a record references it.** The PDS can't see links inside blobs, so
  blobs that point to other blobs (how IPFS stores big files) would be garbage-collected. Every
  link to a blob has to be in a record, and records are capped at 1 MiB.
- **No compare-and-swap.** `putRecord` and `applyWrites` take no expected version, so the last
  write wins.
  - **So no Dolt- or git-style tree with one root.** That design works only because moving the
    head is a compare-and-swap. Without one, two devices that each build a new root from the same
    old one silently overwrite each other.
  - Every edit would also rewrite each folder above it, up to the root, so edits in unrelated
    folders would compete for the same records.
  - One record per file stays: edits to different files never touch the same record. Anything
    several devices write gets one record per writer.
- **What there is instead:**
  - Create-if-absent: `createRecord` and `applyWrites#create` fail with `RecordAlreadyExists`.
  - Updates and deletes of a missing record fail with `RecordNotFound`.
  - `applyWrites` is one transaction of up to 200 writes.
- **There's a change feed:** `com.atproto.space.listRepoOps(since:)` returns every write after a
  revision, with the record values. It isn't history: the server may compact it.
- **`listRecords` lists a whole collection.** It can't start at a key or prefix: only a cursor
  and `reverse`.
- **A space's commit is a set hash** (LtHash over the repo's records), not a Merkle tree. There's
  no server-side tree to reuse; the change feed finds what changed.
- **Blobs are content-addressed** (CID = SHA-256 of the bytes), so identical chunks are stored once.
- **Self-hosted PDSes default to a 5 MB blob limit,** so chunks stay at most 4 MiB.

**Not doing:**
- **A DHT:** handle → DID → PDS already says where everything is.
- **Erasure coding:** one PDS is one point of failure, and shards on it protect nothing.
- **A root that every write goes through:** see compare-and-swap above. Version records (step 2)
  give the useful parts: the drive as of any time, and cheap comparisons.
- **Per-device logs (Hypercore):** the change feed plus `ConflictRules` already cover it.

### Step 1: incremental sync

- **Sync must never mistake "can't see it" for "deleted".** Today two things look like deletions
  to `SyncPlan`, so it would delete local copies:
  - A record this device can't read: `Drive.tree()` drops it. After step 3, that includes a record
    sealed with a key this device doesn't have yet.
  - A drive that's gone, say because the alpha PDS was wiped: on `SpaceNotFound`, `tree()` returns
    an empty drive. The local folder may then be the only copy left.
- **The fix:**
  - `tree()` returns unreadable records as unknown. Sync and the Mac extension leave those IDs
    alone and say why.
  - A missing drive that this device has synced before stops sync, as a missing folder does.
- **Applying changes:**
  - `Spaces.swift` gets `listRepoOps`. `Drive.changes(since:)` turns ops into upserts and deletes,
    and `DriveTree` applies them.
  - `FolderSync` and `DriveIndex` keep the tree and its revision, and apply changes instead of
    listing everything. A poll becomes one request, which returns nothing when nothing changed. It
    replaces `getLatestCommit`.
- **Gaps:**
  - Each op's `prev` must equal the CID we hold for that record (none for a create). A mismatch, an
    error, or no saved revision means a full listing, as today.
  - Checking our records against the commit's LtHash would catch everything. It needs BLAKE3,
    which swift-crypto lacks: later, if at all.
- Persisting the tree also covers the Mac's "persist snapshots across extension restarts".

### Step 2: history

Thirty days of every change: edits, renames, moves and deletes.

- **One version record per change.**
  - Every write to a file or folder also writes a `me.jsnelgro.atdrive.version` record, in the
    same `applyWrites`. Its rkey is a new TID (when).
  - It holds the node's ID; the kind of change (created, edited, moved, deleted, restored); the
    device; and `prev`, the version the change was based on.
  - It also holds the node's state after the change: name and folder, and, for files, size, hash,
    modified time and chunks.
  - A rename or move doesn't copy the chunk list. It names the version that holds the contents, so
    it's tiny.
- **The node record stays the current state,** so listing the tree is still one collection. It
  also names its current version.
- **Versions keep old chunks alive:** the PDS deletes a blob only once no record references it.
- **Two devices changing the same file at once can't lose an edit.**
  - Today the second node update silently replaces the first (README, "Current limitations").
  - Version records have unique keys, so both survive even when one node update wins. Their shared
    `prev` shows the race.
  - Any client that sees a version the node's current version doesn't descend from applies
    `ConflictRules` to it, as for changes in two places today:
    - A lost edit comes back as a conflicted copy, or restores the file if the winner deleted it.
    - A lost move is dropped (the drive's move wins), but stays in history.
  - The conflicted copy's node ID is the lost version's ID, written with create-if-absent, so two
    clients that notice the same race make one copy.
- **The drive as of a time T** in the last 30 days: for each node, its newest version from before
  T. No version, or a delete, means it didn't exist then.
- **Trash** is the deletes of the last 30 days: nodes whose newest version is a delete.
  - Restoring one creates the node again under its own ID, from the version before the delete (a
    create, so it fails if the node is already back). It also writes a "restored" version.
  - It brings back the folders it was in, if they were deleted too.
- **Folders:** deleting a folder deletes, and versions, everything in it. That's one node delete
  and one version per item, deepest first, 100 items per `applyWrites`.
- **Finding a file's versions:** clients list the `version` collection once, then keep it current
  with the change feed, which includes record values.
- **Pruning:**
  - The retention (30 days) is in the drive's `me.jsnelgro.atdrive.settings` record (rkey `self`),
    so every device agrees.
  - Versions older than that are deleted, except what's needed to know each node's state at the
    start of the window: its newest older version, and the version that one takes its contents
    from.
  - A node deleted before the window loses all of its versions.
  - Any device may prune during a sync pass. If another device already deleted a version, the
    batch fails with `RecordNotFound`; retry without it.
  - Deleting versions lets the PDS delete chunks nothing else uses. Storage grows with how much
    changes, not with how many versions are kept.
- **Purging** deletes a file or folder and all of its versions now, for things that mustn't stay
  around.
- **Later:**
  - **Thinning past 30 days** (one a day, then one a week), as Dropbox does. It only changes which
    versions pruning deletes.
  - **Snapshots:** `atdrive snapshot` writes records listing every node's current version, and
    pruning keeps whatever a snapshot lists. The drive as of that moment stays restorable past 30
    days, and costs only the chunks that change afterwards.
- **Caveat:** times come from the writing device's clock.

### Step 3: encryption

Drives are encrypted only. Spaces' access control still applies; encryption protects against the
PDS operator.

- **Records** (`node`, `version`, and `chunks` from step 4):
  - Only what the PDS needs stays readable: `chunks` (so blobs are kept) and a key ID.
  - Everything else, `parent` included, is `sealed`: AES-GCM under a key derived from the drive
    key. The collection and rkey are associated data, so the PDS can't swap records between files.
  - There's no plaintext `sha256`: it would let the server confirm you hold a known file.
- **Chunks: keyed convergent encryption,** as in Tahoe-LAFS and borg:
  - A chunk's ID is HMAC(drive key, plaintext), and its key is derived from that ID. Each key
    encrypts exactly one plaintext, so AES-GCM can use a fixed nonce.
  - Identical chunks encrypt to identical bytes, so they're stored once and step 4 can skip them.
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
  - Which chunks are shared between files and versions.
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
    - Old keys are kept, wrapped by the new one, to read older records and versions.
    - What the removed device already had stays readable to it.
  - Losing every device and the recovery key loses the data. Creating the drive says so, next to
    the recovery key.

### Step 4: transfer only changed chunks

- **Content-defined chunking (FastCDC):**
  - Boundaries follow the content, so an insert near the start changes one or two chunks instead of
    every chunk after it. A new version then costs only those chunks.
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

### Lexicons

Add `version`, `settings`, `device` and `chunks` to `lexicons/`, to `drive.json`'s
`collections`, and to the narrow OAuth scope.

### CLI

| Command | What it does |
|---|---|
| `history [path]` | Changes to a file, or to a folder and everything in it (the whole drive without a path): when, what, which device |
| `ls` / `tree` / `get` / `cat --at <when>` | The drive as it was. `<when>` is `2h` or `3d` (ago), `2026-11-08`, `2026-11-08T14:00`, or a version ID. Paths are looked up as of then, so something moved since is found under its old path |
| `restore <path> --at <when>` | Put a file or folder back as it was: contents, name and place. For a folder, everything in it too. It's recorded as new versions, so it can be undone |
| `restore <path> --previous` | Undo a file's latest change |
| `trash` | What was deleted in the last 30 days |
| `trash restore <path>…` | Bring things back where they were |
| `purge <path>…` | Delete now, with all history |
| `trash empty` | Purge everything in the trash |
| `du` | Space used by current files and by history, and what they share |
| `prune` | Apply the retention now |
| `devices` | The devices that hold the drive key |
| `devices approve <code>` / `devices remove <name>` | Add or remove one |
| `unlock` / `recovery-key` | Set up this device with the recovery key / make a new recovery key |

The time is a flag rather than part of the path (`path@when`), because file names can contain `@`
(`icon@2x.png`).

On the Mac, trash and history start in a menu-bar window. A Finder right-click action ("Restore
Previous Version…", a File Provider custom action) could open it there. Whether Finder can show
history itself is an open question.

### Tests

- **`FakePDS` gains:**
  - `listRepoOps`, with compaction, to test gaps.
  - Create-if-absent, and `RecordNotFound` in `applyWrites`.
  - Blob garbage collection: a blob disappears once nothing references it, so history that doesn't
    keep its chunks fails a test.
  - A way to wipe the space, for the missing-drive guard.
- **The guards:** a record this device can't read, and a drive that's gone, must not delete local
  files.
- **History replay:**
  - Run random edits, renames, moves, deletes and restores, snapshotting the tree as they go.
  - Check that the drive rebuilt for each snapshot's time matches the snapshot, before and after
    pruning.
- **Races:** two devices change the same file at once. Both versions must survive, and exactly one
  conflicted copy must appear, even when both devices notice the race.
- **Chunking** gets fixed test vectors, so every platform cuts the same boundaries.

### Open questions

- **Create-if-absent:** is it reliable under concurrent writes on the live PDS? Restores and
  conflicted copies rely on it.
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

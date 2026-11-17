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
- [x] **Storage v2** (see *Storage v2* below): incremental sync; 30 days of history (edits,
  renames, moves, deletes) that also stops races from losing edits; optional encryption (off by
  default, switchable at any time); and transferring only changed chunks.
  - **Tested** with unit tests against `FakePDS` on Linux, also with a 512 KiB stack (what Apple
    platforms give threads other than the main one). macOS CI builds the app.
  - **Not yet exercised:** any of it against the live alpha PDS, and the Mac app's new screens on a
    real Mac.
  - **Follow-ups:**
    - **Live PDS:** run `LiveTests` and `LiveChangeFeedTests` (they need `ATDRIVE_LIVE_HANDLE`,
      `ATDRIVE_LIVE_PASSWORD`, and `ATDRIVE_LIVE_RECOVERY_KEY` for an account that has a drive).
      Unverified there: `listRepoOps`, `listRecords` across collections, `createRecord`,
      `applyWrites` results, and the OAuth scope with the new collections.
    - **Mac:**
      - Try sign-in, the recovery key window and approval on a real Mac.
      - Approve and remove devices from the app (the CLI does it today).
      - Show history and the trash ("Restore Previous Version…" from Finder).
      - `item(for:)` answers `noSuchItem` for records it can't read.
      - Deleting a folder in Finder ignores unreadable items inside it.
      - Log when the drive doesn't match its commit.
    - **Mac:** turning encryption on and off from the app (the CLI does it today), and a way
      out of "the drive's settings can't be believed" other than the CLI.
    - **Encryption:** see *Step 3, open problems*, and `docs/SECURITY.md` for the review. A
      removed device keeps its session, and `.atdrive/drive.json` holds decrypted metadata.
- [ ] **Phase 5, sharing** (see *Sharing* below): share a file or folder with specific people, or
  with anyone who has its link, read-only, from Finder and the CLI, on encrypted and unencrypted
  drives alike. Tracked in #26.
- [ ] **Later:**
  - Publish the lexicons and narrow the OAuth scope (see below).
  - Shared folders others can edit (#25).
  - `x-callback-url` actions, for Shortcuts and other apps (#31).

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

## Storage v2

Goals:
- Fetch only what changed, and upload only what changed.
- Keep 30 days of history: edits, renames, moves and deletes. The trash is part of it.
- Never lose an edit to two devices writing at once.
- Let people keep file contents and names unreadable to whoever runs the PDS, if they want that
  and are willing to look after keys. Encryption is optional, off by default, and can be turned
  on or off at any time (see *Encryption is optional*).

There are no users yet, so none of this is backward compatible. The format changes in place, and
existing test drives are wiped, not migrated. Built in four steps, in this order. Steps 2 and 3
end with what was decided while building them ("As built").

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
  - After the last page, check our copy against the commit. Its `data` is an LtHash over every
    record in the repo (`RepoSetHash` in `LtHash.swift`, on `BLAKE3.swift`). A mismatch means a
    full listing.
  - The check covers every collection, including ones this client doesn't understand. Those are
    tracked by CID without being decoded, so they can't make the check fail forever.
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
- **Caveat:** times come from the writing device's clock, which also decides which side of a race
  lost.
- **As built:**
  - **Node records name their contents version too** (`contentsFrom`), so a move doesn't have to
    look up the current version to find the chunks.
  - **What happens to a lost change** is `ConflictRules.lostChange`:
    - A lost edit becomes a conflicted copy (made once, under the lost version's ID).
    - If the winner only moved the file, the lost edit's contents go on the file instead.
    - If the winner deleted the file, the lost edit restores it.
    - A lost move or delete is dropped, but stays in history. A move can't bring back a deleted
      file: only edits and restores do.
  - **The drive as of a time** follows each node's line of changes. Changes that lost a race show
    in `history`, not in the past view. Only races within the retention period are settled.
  - **Items deleted with their folder** are those deleted within a second before it. They're
    hidden from the top level of the trash, and come back with the folder.
  - **Restoring a folder to a time** brings back what was in it then, and leaves what's been
    added since.
  - **Drives are created only on purpose** (`createsDrive`). Sync saves the drive's ID and when it
    last pruned in `state.json`.
  - **The OAuth scope** names the new collections, so sessions from before need a new sign-in.

### Step 3: encryption

How an encrypted drive works. Whether a drive is one is the next section, *Encryption is
optional*. Spaces' access control applies either way; encryption protects against the PDS
operator.

- **Records** (`node`, `version`, and `chunks` from step 4):
  - Only what the PDS needs stays readable: `chunks` (so blobs are kept) and a key ID.
  - Everything else, `parent` included, is `sealed`: AES-GCM under a key derived from the drive
    key. The space, collection and rkey are associated data, so the PDS can't swap records
    between files, or between drives.
  - There's no plaintext `sha256`: it would let the server confirm you hold a known file.
- **Chunks: keyed convergent encryption,** as in Tahoe-LAFS and borg:
  - A chunk's ID is HMAC(drive key, plaintext), and its key is derived from that ID. Each key
    encrypts exactly one plaintext, so AES-GCM can use a fixed nonce.
  - Chunk IDs, and step 4's chunker seed, always come from the drive's **first** key, even after
    rotations. Otherwise every file's chunks would get new IDs and boundaries after a device is
    removed, and nothing would be reused.
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
  - **The drive key** is 32 random bytes, made when the drive is created. The keyring is every
    drive key so far, oldest first; the newest seals new records.
  - **Each device has its own key pair** (Curve25519), stored where its session is.
  - **One record per device** (`me.jsnelgro.atdrive.device`) holds the keyring wrapped for that
    device's public key. One more (rkey `recovery`) wraps it for the recovery key. They're separate
    records because two devices editing one shared keyring record would overwrite each other.
  - **Wrapping uses HPKE in auth mode** (X25519, HKDF-SHA256, AES-256-GCM: all in WebCrypto, so
    a browser can be a device), bound to the space, so a device can tell which device wrapped its
    keyring.
    Anyone can wrap a keyring for a public key, the PDS included. A device accepts one only from
    itself or from a device it has confirmed, so the PDS can't get it to seal new records under a
    key the PDS knows.
  - **The recovery key** is 256 random bits, shown once when the drive is created as 14 groups of 4
    letters and digits (Crockford base32, with a checksum that catches typos). It's high-entropy,
    so it needs no password KDF (swift-crypto has no Argon2).
  - **Adding a device:** `atdrive login`, then one of:
    - `atdrive unlock` with the recovery key.
    - Approve it from a device that has the key:
      - The new device posts its public key. The approving device posts its own.
      - Both show a 16-digit code computed from the two keys, and the user confirms on both that
        they match.
      - Only then does the approver wrap the keyring for the new device. The new device accepts it
        only from the approver it confirmed.
      - 16 digits, because the PDS sees the keys first. Against a shorter code, it could try keys
        of its own until one matched.
  - **Removing a device:**
    - Delete its record, and add a new drive key for new records. Wrap the keyring again for the
      remaining devices and the recovery key.
    - What the removed device already had stays readable to it.
    - It also keeps the first key, so it can still test whether the drive holds a chunk it already
      knows. That's the price of keeping chunk IDs stable.
    - It still holds a session for the account, so it can still write records. Remaining devices
      ignore keyrings it wraps.
  - Losing every device and the recovery key loses the data. Creating the drive says so, next to
    the recovery key.
  - **Creating a drive is interactive,** because it has to show the recovery key: `atdrive login`
    does it (and unlocks, or asks for approval, on a drive that exists), and so does the Mac app's
    first sign-in. The background `atdrive sync` service never creates a drive.
- **As built:**
  - **Only `create()` makes a drive,** from `atdrive login` or the Mac app's first sign-in. Writes
    never do, and `atdrive sync` and `put` on an account with no drive say to run `atdrive login`.
  - **The roster** (the approved devices) is one sealed membership per device, in its own device
    record (`member`: its ID, name and public key, sealed with the drive's *current* key for that
    record). When keys rotate, the keyring is wrapped only for devices whose membership opens,
    never for keys merely read from device records, which the PDS can change.
    - It was first built as a list in the settings record, where two approvals at once could
      overwrite each other (#13). One record per device fixes that: an approval writes only the
      new device's record.
    - Removing a device rotates the key and seals every remaining membership again, so the PDS
      can't bring a removed device back by restoring its old record.
    - A device approved at the very moment another is removed is left with the old keys, and has
      to be approved again. That fails safe.
  - **A device takes a keyring only if** it holds every key the device accepted before (devices
    keep fingerprints of past keys, so made-up or replayed keyrings are refused), and it was
    wrapped by the device itself, by its confirmed approver (its first keyring only), or by a
    device in the roster.
  - **The pairing code** is SHA-256 over both devices' public keys, sorted, shown as 16 digits.
  - **Device records aren't sealed,** since a waiting device has no key yet. The PDS sees device
    names.
  - **Removing a device asks for the recovery key,** since only it can wrap the new keyring for
    recovery. Pressing Enter instead makes a new recovery key and shows it.
  - **Each device's key** is in `device.json` (mode 600) beside `session.json`, or in the App Group
    container on the Mac. The keyring itself is never stored; it's unwrapped from the device's
    record, and again whenever that record changes.
  - **Approving and removing devices** is CLI-only for now. The Mac app can create a drive, show
    the recovery key, unlock with it, and be approved.
  - **Open problems:**
    - A removed device keeps an account session, and records it writes with old keys are still
      read.
    - `.atdrive/drive.json` holds decrypted metadata next to the synced files.


### Encryption is optional

Decided after step 3 was built encrypted-only: encryption is off by default, for people who'd
rather trust whoever runs their PDS than risk losing keys, and can be turned on or off at any
time. The format is specified in `docs/FORMAT.md`.

- **Each record is plain or sealed, and says which** (a sealed one has a `sealed` field). Every
  client reads both. So a drive can be a mix while it's converted, a conversion can stop and
  resume, and nothing depends on one big atomic switch, which spaces couldn't give us anyway.
- **The drive's mode is how its settings record is stored:** plain, or sealed. A device reads it
  when it opens the drive (`Drive.open`) and again whenever that record changes, and writes in
  that form. A drive can't be written to before it's opened.
- **A plain drive** stores records' fields and files' bytes as they are. Chunks are named by
  their blob CIDs, and the chunker's seed is fixed. It has no keys, devices or recovery key, and
  a device needs no identity. History, the trash, the change feed, the LtHash check, FastCDC and
  skipping chunks already uploaded all work the same: `scripts/test.sh` runs the drive-logic
  suites on both.
- **Turning it off is one write.** The settings become plain and publish the drive's keys
  (`retiredKeys`); the device records go.
  - Everything sealed stays readable with the published keys, to every device and to the PDS,
    so nothing has to be rewritten and no device can be left holding records nobody can read.
  - The published keys are also the proof. A device that held the keys believes the drive
    stopped being encrypted only if the settings publish them: its own devices can, the PDS
    can't. Otherwise it refuses to write (`encryptionRemoved`), so the PDS can't get a device to
    start writing in the clear by swapping the settings record.
  - `convert` then rewrites records as plain ones, for clients that can't decrypt. Optional.
- **Turning it on is the expensive direction.** New keys, a recovery key, and the settings
  sealed with `converting` set, in one write. Then `convert` rewrites every record and stores
  every file again, encrypted, history included (versions keep their IDs), and clears
  `converting`.
  - The CLI says how much there is and asks first. It can be interrupted and resumed, on any
    device with the keys.
  - While `converting`, devices still read plain records. Once it's cleared they don't: on an
    encrypted drive, a record that isn't sealed with its keys could be the PDS's.
  - A device that hadn't noticed the switch may write plain records after that. They're held as
    unreadable, never taken for deletions, and `atdrive encryption on` offers to adopt them.
  - Settings carry a `generation`, and a device refuses sealed settings older than ones it has
    read, so the PDS can't replay the `converting` settings to get its own records read.
  - Other devices must be approved again: the keys are new.
- **Chunks say which key named them** (`chunkKey`), so a conversion can tell a chunk encrypted
  under the current keyring from one left over from before, whatever record now points at it.
- **Long chunk lists** are rewritten into new `chunks` records numbered after the old ones
  (`continuationsFrom`), and the version and node switch to them in one write.
- **A race during conversion** (another device edits a file as its record is rewritten) shows
  up as a lost change and is settled like any other. Nothing is lost.

### What this means for sharing and the web

Checked against the sharing plan (#26, #27) and the web milestone while reworking the format:

- **One `Drive` is one space,** with its own mode, keyring, history and change feed. A drive
  made of several spaces (mounts, #19) is several of them; nothing in the core assumes the
  space is the account's own, or its only one.
- **Sealing and key wrapping are bound to the space,** so a record or a wrapped keyring can't be
  replayed from the home drive into a shared space or back, even if they ever share a key.
- **Device trust is kept per space,** not one per device.
- **Each space has its own mode,** so an encrypted drive can hold a plain share. Not the other
  way round: a plain drive's mount would hold the share's keyring readable (see *Sharing →
  Encrypted and plain shares*).
- **Memberships are one sealed record each.** Member records for shares (#22) should take the
  same shape: one record per member, sealed with the share's current key, re-sealed on rotation.
- **Turning a share's encryption off** publishes that share's keys, not the drive's.
- **Turning the home drive's encryption off** publishes the home keys, and with them what's
  sealed in the home drive: the keyrings of encrypted shares (in mounts) and the account's
  sharing key. *Sharing → Encrypted and plain shares* says what happens to each first.
- **A web client** needs no cryptography for a plain drive, which is the default, and only
  WebCrypto for an encrypted one. See `docs/FORMAT.md`, *A web client*.
- **Not done here:** node IDs as (space, rkey), mounts, credentials for other accounts' spaces.
  Those are #18 and #19.

### Step 4: transfer only changed chunks

- **Content-defined chunking (FastCDC):**
  - Boundaries follow the content, so an insert near the start changes one or two chunks instead of
    every chunk after it. A new version then costs only those chunks.
  - Min 256 KiB, average 1 MiB, max 4 MiB. The mean comes out at about 1.1 MiB, since nothing is
    cut before 256 KiB.
  - The chunker is seeded from the drive's first key, so chunk sizes don't fingerprint files and
    boundaries don't move when keys rotate.
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
`collections`, and to the narrow OAuth scope. The schemas describe the plain form; a sealed
record has only `chunks` and `sealed`.

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
| `encryption` / `encryption on` / `encryption off` | Whether the drive is encrypted; turn it on (and convert what's there) or off |
| `devices` | The devices that hold an encrypted drive's key |
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

## Sharing

Share a file or folder with specific people, or with anyone who has its link. Read-only first;
editing together comes later (#25). Works on encrypted and plain drives. Builds on Storage v2 and
optional encryption, and like them isn't backward compatible.

Goals:
- Share from Finder (right-click) and from the CLI.
- What's shared with you shows up in your own drive: in Finder, and in `atdrive sync` folders.
- **Links open ATDrive directly** (`atdrive://`). Nothing hosted: no web viewer, no relay, no
  redirect page. Opening a link needs ATDrive.
- An encrypted share stays unreadable to whoever runs the PDS, even behind a public link.

### What shapes the design

Checked against the reference branch at `83d473d` (2026-11-13):

- **Access is set per space, not per record.** Anything shared with different people needs its
  own space, so a shared folder becomes a space.
- **The `memberspace` policy:**
  - A member list with read and write access per account: `putMembers`, `removeMembers`,
    `listMembers`.
  - `publicRead`, `publicWrite`, and `allowedApps` (OAuth client IDs allowed to read).
  - `updateSpace` changes a space's policy. Changing the policy type discards the member list.
  - All of these need `manage=update` in the OAuth scope.
- **Reading someone else's space** takes three steps:
  1. Your own PDS signs a delegation token (`getDelegationToken`). Your OAuth scope must allow
     reading that space, and a scope's authority defaults to `self`, so this needs
     `authority=*`.
  2. The owner's PDS trades the token for a credential (`authorizeSpaceSync`), bound to a P-256
     key the reader chooses.
  3. Reads (`listRecords`, `listRepoOps`, `getLatestCommit`, `getBlob`) send
     `Authorization: Atproto-Space-Credential <credential>`, signed with that key (HTTP Message
     Signatures, RFC 9421).
  - With `publicRead`, step 1 is skipped: reading needs no account at all.
  - Non-members get `SpaceNotFound`, so a space's existence isn't revealed.
- **Removing a member really works,** unlike removing a device: the PDS stops serving them. What
  they already downloaded stays theirs.
- **There's no "shared with me" list.** `listSpaces` returns only spaces you own or have written
  to. A link has to reach the recipient some other way (a message, an email).
- **Blobs belong to the account,** and are linked to records per space (`space_record_blob`). So
  a record in a new space can probably reference chunks that are already uploaded, and sharing
  uploads nothing. Still to be checked on the live PDS (#17).
- **Each writer has their own repo in a space,** on their own PDS, and can't change anyone else's
  records. That matters only once others can edit.
- **Sealing binds a record to its space, collection and rkey.** Records moved to an encrypted
  space are sealed again under its keyring, for that space.

### Shared folders are drives

- **A shared folder is a space of the drive's own type:**
  `at://<owner>/space/me.jsnelgro.atdrive.drive/<skey>`, under `memberspace`.
  - It's a drive in every way: nodes, versions, chunks, and `settings` with its mode.
  - An encrypted share has its own keyring, including its own first key for chunk IDs and the
    chunker seed.
  - History, the trash, pruning, the change feed and the LtHash check work in it as in the home
    drive.
- **Its space key is 128 random bits** (base32), not a TID. A plain share's public link has only
  its address to protect it, so the address mustn't be guessable.
- **A single file can be shared** the same way: a space holding one node.
- **Mounts:** a node of kind `mount` marks where a space appears in a drive. It holds the space's
  address and, for an encrypted space you own, its keyring. Being a node, it can be renamed and
  moved, and has history, like a folder.
  - **The tree** joins each mounted space's tree in at its mount. A node's ID becomes (space,
    rkey) everywhere: the tree, sync state, history, and the Mac's item identifiers. Paths cross
    mounts, so `ls`, `get`, `put`, `mv`, `rm`, `history` and `--at` work across them.
  - **Sync** runs the change feed and the LtHash check per space. A poll is one request per
    space. The Mac's sync anchor holds every space's position.
  - **A mount whose space is gone or unreadable is held,** like a record this device can't read:
    nothing under it is deleted locally, and sync says why.
  - **Only the home drive is ever created by a write.** A missing shared space stays missing.
  - **A move across a mount** is a copy into the other space, then a delete. The node gets a new
    ID, and a version on each side records the move. Chunks are reused between spaces of the same
    mode. Between an encrypted and a plain space they're downloaded and uploaded again.
  - **No nesting for now.** Nothing inside a mount can be shared, and a mount can't be moved into
    another mount.

### Encrypted and plain shares

- **A share takes its drive's mode** by default.
- **From an encrypted drive, `--plain`** makes a plain share: its files are decrypted and uploaded
  again, readable by the PDS. It's an explicit choice, with a warning.
- **A plain drive makes plain shares only:** its owner has no keys to protect an encrypted one
  (the mount that would hold the share's keyring is readable).
- **A share keeps its mode when the drive's changes,** and has to be dealt with first:
  - **Turning the drive's encryption off** publishes the drive's keys, and with them the keyrings
    of encrypted shares in its mounts, and the sharing key. So it lists those shares and asks:
    make each plain too (the same switch, on that space), or stop sharing it. For shares other
    people own, the mount is removed, and can be opened again afterwards as a plain drive does.
  - **Turning it on** leaves plain shares plain. Each can be switched by its owner like a
    drive (`atdrive encryption on <path>`), which converts it and re-wraps for its members.
- **A share's mode is switched like a drive's:** its settings record says which it is, and
  `convert` rewrites what's there. Members follow as devices do: they believe a share stopped
  being encrypted only if its settings publish the keys they held.
- **Anyone can open either kind,** whatever their own drive's mode. When an encrypted share goes to
  someone with a plain drive, their sharing key (below) is stored readable on their PDS, so
  whoever runs that PDS could read the share. ATDrive warns the owner when adding them, and marks
  them in `share ls` and the Share window. It doesn't block it.

### Sharing a folder

`atdrive share <path>` moves a file or folder into its own space:
1. Create the space (`memberspace`, no members, not public), in the share's mode. An encrypted
   share also gets a new keyring.
2. Write the current nodes into it, keeping their rkeys, sealed under the new keyring if it's
   encrypted. Chunk IDs and blob refs are reused, so nothing is uploaded (except for `--plain`
   from an encrypted drive). Each node gets one `created` version.
3. Write the mount in the folder's place, and delete the originals, in `applyWrites` batches.
   The originals get a `shared` version, which the trash skips.

- **History stays behind.** The shared space starts from the current state, so members see
  changes from the moment of sharing, never what came before (an old draft, a removed
  paragraph). The old versions stay in the home drive's history until they're pruned.
- **An interrupted share** finishes when `share` runs again: nodes keep their rkeys, so it can
  tell what's been copied. Until then the folder may show twice. It never disappears.
- **Unsharing** (`atdrive unshare <path>`): remove every member and the link, add a new key (if
  encrypted), and set the policy back to `personalspace`. The folder stays a mount; nothing moves
  back.
- **`delete-drive` (#16)** should also offer to delete the shared spaces the account owns. Mounts
  of other people's spaces just go.

### Keys for encrypted shares

- **A shared space's keyring** works like a drive's:
  - The owner's devices get it from the mount, sealed in the encrypted home drive.
  - Members get it from their member record.
  - Holders of a public link get it from the link record.
- **Each account has a sharing key,** an X25519 key pair, made when its drive is created (both
  modes).
  - **The private key** is kept with the home drive's keyring on an encrypted drive. On a plain
    drive it's kept in the drive's `settings`, readable: that's the case the owner is warned
    about.
  - **When the drive's encryption is turned on or off,** the account gets a new sharing key (the
    old one was, or becomes, readable), published with its new `protected` value. Owners of
    shares it's a member of wrap their keyrings for it again, as after a device removal.
  - **The public key** is published in the account's public repo (`me.jsnelgro.atdrive.shareKey`,
    rkey `self`), with whether the private key is kept encrypted. Anyone can find it from a
    handle.
  - **Someone without a sharing key** (no ATDrive yet) can't be added to an encrypted share. Send
    them a link instead.
- **Member records** (`me.jsnelgro.atdrive.member`, rkey = the member's DID) are in the shared
  space. Each holds the space's keyring, wrapped for that member's sharing key with HPKE in auth
  mode from the owner's sharing key. The member accepts it only if the sender is the key the owner
  published. Like device records, each also seals its membership with the share's current key,
  so the PDS can't restore a removed member's record.
- **The link record** (rkey `link`) holds the keyring sealed with a random 256-bit link key. The
  link carries that key after the `#`, and ATDrive never sends it to any server.
- **Removing a member, or turning the link off,** adds a new key for what's written afterwards. As
  with devices, what they already had stays readable to them.
- **Trust:** a published sharing key is only as trustworthy as its owner's PDS, which signs the
  repo it's in. A malicious PDS could publish a key of its own and receive the keyring.
  Verification codes that both people compare, as devices do when pairing, are #30. Until then
  ATDrive shows each member's key fingerprint and warns when one changes.
- **Removing a device (#14):** the sharing key rotates along with the drive key, and owners wrap
  keyrings again for the new key once it's verified (#30).

### Links

- **Format:** `atdrive://open?at=<the space's at:// address, URL-encoded>`, plus `#<link key>` for
  an encrypted public link.
  - The CLI also takes the bare `at://` address.
  - A link works for members and, with `publicRead` on, for anyone.
- **Opening one** needs ATDrive:
  - **On a Mac,** the menu-bar app registers the `atdrive` scheme (`CFBundleURLTypes`,
    `onOpenURL`). It shows what's shared and offers "Add to My Drive" or "Download".
  - **On Linux,** `atdrive sync --install` also registers a desktop handler for
    `x-scheme-handler/atdrive` that runs `atdrive open <link>`.
  - **In the CLI:**
    - `atdrive open <link>` adds it.
    - `atdrive get <link> [dest]` downloads it once. A public link works signed out.
    - `atdrive shared add|ls|remove` manages mounts of other people's spaces. A mount is added at
      the top level, renamed if the name is taken.
  - **A link to a space that isn't an ATDrive drive** goes to the apps view (#28), not the drive.
- **Clickability:** many email and chat apps don't make `atdrive://` links clickable, so people may
  have to copy and paste. If that turns out to be a real problem, the smallest fix is one static
  redirect file (no server, and the link stays in the `#fragment`). It's not part of this plan.
- **Read-only mounts:** Finder gets no write capabilities for their items. In `atdrive sync`,
  local changes inside one are held and reported, never uploaded and never deleted.
- **Losing access** (removed, unshared, or the space deleted): the mount is held, and says why.
  Local copies stay.

### Finder

- **Right-click actions,** as File Provider custom actions (`NSExtensionFileProviderActions`,
  `NSFileProviderCustomAction`). These need no UI extension:
  - **Share…** opens a window in the menu-bar app: who has access (marking members whose drive
    isn't encrypted), adding people by handle, removing them, and turning the link on or off.
  - **Copy Link** and **Stop Sharing.**
  - Which ones show depends on the item (yours and shared, shared with you, or neither), through
    predicates on the item's `userInfo`.
- **Badges:** a `Sharing` decoration on shared folders and on mounts shared with you. Not the
  item's `isShared`: Finder labels those "shared on iCloud".
- **No FileProviderUI extension.** It would be a second extension target, and developers report it
  being fragile on macOS. The menu-bar app already has windows, and handles `atdrive://` links.

### Lexicons and scope

- **New records:** `mount` as a node and version kind; `mode` in `settings`;
  `me.jsnelgro.atdrive.member` in the drive space type's collections;
  `me.jsnelgro.atdrive.shareKey` in the public repo.
- **The default scope adds:**
  - `manage=update`.
  - Read access to ATDrive drive spaces of any authority (`authority=*`), and only those.
  - Writes to `me.jsnelgro.atdrive.shareKey`.
  - #17 settles the exact syntax.
- **#28's read-everything scope** stays a separate, opt-in upgrade.
- Publishing the lexicons (and `narrowScope`) can still wait. Sharing doesn't need it.

### How it relates to #28 (other apps' data)

- Both use the credential client (#18), and the live probes (#17) run together.
- `atdrive://` links route by space type: an ATDrive drive is mounted, and anything else opens in
  the apps view.
- Mount nodes are where the drive keeps the spaces shared with it. #28 has the same question for
  other apps' spaces, and could keep its list the same way.

### Later

- **Editing together (#25).** Several writers' repos in one space, each on its writer's own PDS:
  - The tree is the union over `listWriters`. A node's state follows its versions across writers:
    `prev` names a repo and a version, and `ConflictRules` settles races between people as it does
    between devices.
  - A member's chunks are blobs on their PDS, read there with the same credential.
  - Removing a writer: `removeMembers`, then `removeWriter`, and the key rotates.
- **`x-callback-url` actions (#31):** for example
  `atdrive://x-callback-url/share?path=…&x-success=…`, which hands the link back to Shortcuts or
  another app.

### Order

Storage v2 (#7) merges first: it includes optional encryption (#29 was folded into it). Then
sharing. Each step has an issue; #26 tracks them all.

| Step | Issue | Waits for |
|---|---|---|
| Check the protocol on the live alpha PDS | #17 | — |
| Spaces client: members, and reading other accounts' spaces | #18 | #7, #17 (scope string, signature details) |
| Mounts: a drive made of several spaces | #19 | #7 |
| `atdrive share`: move a file or folder into its own space | #20 | #17, #18, #19 |
| Links (`atdrive://`), and opening them | #21 | #20 |
| Share with specific people | #22 | #21 |
| Finder: actions, badges, and `atdrive://` on the Mac | #23 | #21, #22 |
| Verification codes for sharing keys | #30 | #22 |
| Shared folders others can edit (later) | #25 | #22 |
| `x-callback-url` actions (later) | #31 | #23 |

#17 can start now. Once #7 is in, #18 and #19 can go in parallel.

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

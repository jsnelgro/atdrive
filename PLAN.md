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
    - **Live PDS:** run `LiveTests` and `LiveChangeFeedTests` (they need `ATDRIVE_LIVE_STATE`, a
      folder `atdrive login` saved a session to; spaces refuse app passwords).
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
- [x] **Phase 5, sharing** (see *Sharing* below): share a file or folder with specific people, or
  with anyone who has its link, read-only, from Finder and the CLI, on encrypted and unencrypted
  drives alike. Tracked in #26; built in #42.
  - **Tested** with unit tests against `FakePDS`, which now hosts several accounts and checks
    credentials, request signatures and MACs as the protocol has them. The spaces crypto is
    checked against the reference's vectors. macOS CI builds the app.
  - **Not yet exercised:** against the live alpha PDS (two accounts: `ATDRIVE_LIVE_STATE` and
    `_B`), and the Finder actions, badges, windows and `atdrive://` links on a real Mac.
  - **Follow-ups:** publish the lexicons (`atdrive dev lexicons publish`, then a DNS TXT record at
    `_lexicon.atdrive.app`) and set `OAuthLogin.lexiconsPublished`, which narrows the
    scope to ATDrive's spaces.
- [x] **Spaces** (#28, see *Spaces* below): everything in the spaces you're in, not just
  ATDrive's files, as a read-only folder at the top of the drive: in Finder, a synced folder and
  the CLI. Off unless `spaces.enabled` is on in config.toml.
  - **Tested** with unit tests against `FakePDS` (`listWriters`, `repoRev` in `listSpaces`,
    `resolveLexicon` and `AppNotAuthorized` added). macOS CI builds the app.
  - **Not yet exercised:** against the live alpha PDS (#17's probes for it: is a member-only
    space listed, what does a Bulletin space look like, the scope string, `allowedApps`;
    whether the PDS answers `resolveLexicon`), and the folder on a real Mac: the "can't be read"
    badge and Spotlight's handling of it included.
  - **Later:** spaces shared with you found without their address (#56); public repo data as a
    view of its own, with record type filters (#57).
- [ ] **Later:**
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

- **One drive = one space:** `at://<did>/space/app.atdrive.drive/default`, under the
  `personalspace` policy. It's created on the first write.
- **One record per file or folder:** `app.atdrive.node`. The rkey is a TID and is
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
  - Every write to a file or folder also writes an `app.atdrive.version` record, in the
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
  - The retention (30 days) is in the drive's `app.atdrive.settings` record (rkey `self`),
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
  - **One record per device** (`app.atdrive.device`) holds the keyring wrapped for that
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
    - `atdrive encryption unlock` with the recovery key.
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
  - **Each device's key** is kept beside the session (`SecretStorage`): the Keychain for the CLI on
    a Mac, `device.json` (mode 600) in `$XDG_STATE_HOME/atdrive` elsewhere, or the App Group
    container for the Mac app. Never in `~/.config`, which people keep in version control. The keyring itself is never stored; it's unwrapped from the device's
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
- **Switching a drive's encryption, either way, ends its sharing.** Turning it off publishes the
  home keys, and with them what's sealed in the home drive: the keyrings of encrypted shares (in
  mounts) and the account's sharing key. Rather than handle each case, a switch stops all
  sharing first, and the user shares again afterwards (*Sharing → Encrypted and plain shares*).
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
  `app.atdrive.chunks` records, written in the same `applyWrites`.

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
| `restore <path>` | Something deleted: back from the trash, where it was. Anything else: undo its latest change |
| `trash` | What was deleted in the last 30 days |
| `trash empty [path…]` | Delete what's in the trash (or just these) now, with all history |
| `dev du` | Space used by current files and by history, and what they share |
| `encryption` / `encryption on` / `encryption off` | Whether the drive is encrypted; turn it on (and convert what's there) or off |
| `devices` | The devices that hold an encrypted drive's key |
| `devices approve [name]` / `devices rm <name>` | Add or remove one |
| `encryption unlock` / `encryption rotate-recovery-key` | Set up this device with the recovery key / replace the recovery key |

Retention is applied once a day by `atdrive sync` and by the Mac app.

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

Share a file or folder with specific people, or with anyone who has its link. Read-only;
editing together comes later (#25). Works on encrypted and plain drives. Built in #42; not
backward compatible.

- Share from Finder (right-click) and from the CLI.
- What's shared with you shows up in your own drive: in Finder, and in `atdrive sync` folders.
- **Links open ATDrive directly** (`atdrive://`). Nothing hosted.
- An encrypted share stays unreadable to whoever runs the PDS, even behind a public link.

### What shapes the design

Checked against the proposal and the reference branch on 2026-11-17:

- **Access is set per space, not per record,** so a shared folder is a space of its own.
- **The `memberspace` policy:** a member list (`putMembers`, `removeMembers`, `listMembers`),
  `publicRead`, and `allowedApps`. `updateSpace` replaces the policy; changing its type drops the
  member list (which is all `unshare` needs). These take `manage=update`; `deleteSpace` takes
  `manage=delete`.
- **Reading someone else's space** (0016, "Credential flow"):
  1. Your own PDS signs a delegation token (`getDelegationToken`). It takes a `read` grant for the
     space, under any authority (`authority=*`). Skipped for a public space.
  2. The owner's PDS trades it for a credential (`authorizeSpaceSync`), bound to a P-256 key made
     fresh for each credential. Credentials last about 10 minutes.
  3. Each read carries `Authorization: Atproto-Space-Credential <credential>` and
     `Atproto-Space-Audience` (the repo's DID), signed per RFC 9421 (`ecdsa-p256-sha256`, raw
     `r || s`, tag `atproto-space-credential`).
  4. **Commits come with a MAC:** the reader derives a fresh secret from the owner's
     `#atproto_kem` key (HPKE secret export, P-256) and checks an HMAC over
     `Atproto-Space-Commit`, so a host that isn't the owner's can't serve a commit that passes.
  - Non-members get `SpaceNotFound`; a deleted space answers `SpaceDeleted` (readers should then
    delete their copies, and ATDrive does).
- **Blobs belong to the account** and are linked to records per space; the reference PDS accepts
  a record in a new space referencing a blob already uploaded, and garbage-collects across all
  spaces. So sharing uploads nothing.
- **There's no "shared with me" list:** a link has to reach the recipient some other way.
- **Spaces refuse app passwords** (since 2026-11-16): OAuth only.

### Shared folders are drives

- **A shared folder is a space of the drive's type,** `at://<owner>/space/app.atdrive.drive/<key>`,
  under `memberspace`, its key 128 random bits in base32 (a plain share's public link has only its
  address to protect it). It's a drive in every way: nodes, versions, chunks, and `settings`
  (with its mode, and its `name`, for those who open it).
- **A mount** (a node of kind `mount`) marks where a space appears in a drive. It holds the
  space's address and, for an encrypted space you own, its keyring (and its link key, if its
  link is on); for someone else's encrypted share opened by link, the link key. A plain drive
  refuses to write a keyring into one.
- **A shared file is the file.** Its space holds just that file, and its settings say `file`.
  The joined tree shows the mount as the file (kind `file`, still with its `mount`, under the
  mount's ID and name), not a folder holding it: for its owner, everyone it's shared with, sync
  and Finder alike. Its contents (reading, new versions) go to the file in the space; renaming,
  moving and deleting go to the mount.
- **`JoinedDrive`** joins the home drive and its mounts into one tree. A node's ID is its record
  key at home, `<mount>/<rkey>` in a mounted space: strings, as before, so sync state and the
  Mac's identifiers didn't change shape. Each space follows its own change feed; the Mac's sync
  anchor holds every space's revision.
- **A move between spaces** is a copy, then a delete (a new ID). Chunks are reused between
  spaces of the same mode, and transferred again otherwise.
- **A mount that can't be read is held:** it keeps its last contents, or, never read, shows as an
  unreadable record, so neither sync nor Finder takes what came from it for deleted. A share
  its owner deleted (or unshared) is the exception: it disappears, and its copies go.
- **Other people's shares are read-only:** Finder gives their items no write capabilities. In
  `atdrive sync` the drive's version always wins (`ReadOnlyFolders` in `SyncPlan`): edits,
  deletions, moves and renames made inside one are put back at the next sync, and something of
  yours moved in goes back where it was. What was edited or added in one is kept first, at the
  top of your drive: an edit as a conflicted copy, something new as it is. Nothing is uploaded
  to, or deleted from, the share.
- **Their names are their owners' (#68):** the joined tree shows someone else's share under the
  name its owner gives it (a shared file's name, or a shared folder's `settings.name`), numbered
  if something beside it has that name (`JoinedSnapshot.sharedNames`); the mount record's own
  name is used only until the share has been read. The mount is still yours: it can move
  anywhere in your drive, or be removed, but `JoinedDrive.move` refuses a new name
  (`notYoursToRename`), Finder doesn't offer renaming (and names it back if it happens anyway),
  and a synced folder puts the name back (`ReadOnlyFolders.named`), and a shared file's
  contents too. Renaming a share of yours renames it in its space as well, so everyone who has
  it sees the new name.
- **No nesting:** nothing inside a mount can be shared, and a mount can't go in another.

### Sharing a folder

`atdrive share <path>` (or `JoinedDrive.share`):
1. Create the space, in the share's mode, and **write the mount first**, as `name (sharing…)`,
   holding an encrypted share's keyring (sealed in the drive): nothing is ever lost if it's
   interrupted.
2. Copy the folder's contents (or the file) into it, keeping record keys, each with one
   `created` version. Chunks and their IDs are reused; nothing is uploaded (except for a plain
   share from an encrypted drive, which the core can make but no command asks for).
3. Delete the originals with a `shared` version (the trash skips it), and rename the mount.

- **History stays behind.** Members see the share from the moment of sharing.
- **Running it again** finishes an interrupted share: the mount is found by name, and what's
  been copied by record key.
- **On the command line,** `share <path> <people…>` adds people, and `share <path>` alone turns
  the public link on. `unshare <path> <people…>` takes people off, and once nobody has it (no
  people, no link) it's unshared; `unshare <path>` alone does that straight away.
- **`unshare`:** first back to `personalspace` (dropping members and `publicRead`) with member
  and link records deleted, so access ends at once; then the share moves back into the drive,
  where it is, an ordinary file or folder again, and its space is deleted. Those who had it see
  it disappear. Run again, it finishes an interrupted one. Sharing it again makes a new space
  (and link).

### Encrypted and plain shares

- A share takes its drive's mode. (The core can make a plain share from an encrypted drive; no
  command or button asks for one, since anyone can open an encrypted share from its link.)
- **Switching the drive's encryption ends its sharing:** each share moves back into the drive
  where it was (a shared file comes back as the file) and its space is deleted; mounts of other
  people's shares are removed; the sharing key is replaced. The CLI lists what stops being
  shared, and with whom, first. Moving back, rather than converting each share, means the
  drive's own conversion covers everything, and no keyring is ever left readable.
- Anyone can open either kind. An encrypted share sent to someone whose drive is plain warns the
  owner (their sharing key is readable on their PDS) but isn't blocked.

### Keys for encrypted shares

- **A share's keyring** reaches the owner's devices through the mount (sealed in the drive),
  members through their member record, and link holders through the link record.
- **Each account has a sharing key** (X25519), kept in its home drive's settings (sealed on an
  encrypted drive, readable on a plain one) and published as `app.atdrive.shareKey`
  (`self`), with `protected`. Signing in publishes it; switching encryption replaces it; removing
  a device rotates it.
- **Member records** (`app.atdrive.member`, key = their DID): the keyring wrapped for their
  sharing key with HPKE auth mode from the owner's, accepted only if the sender is the owner's
  published key; and their membership sealed with the share's key, so the PDS can't make one.
- **The link record** (`app.atdrive.link`, `self`): the keyring sealed with a key derived
  from a random 256-bit link key, which travels in the link's `#fragment`.
- **Removing a member, or turning the link off,** rotates the key and wraps it again for those who
  stay. What they already had stays theirs.
- **Verification codes** (#30): 16 digits from both sharing keys, compared out of band. Verified
  keys are kept in the home drive (`app.atdrive.contact`). A key that changed since it was
  verified or last wrapped for is refused unless the owner confirms.

### Links

- **Format:** `atdrive://open?at=<the space's address, URL-encoded>`, plus `#<link key>` for an
  encrypted share's public link. The CLI also takes the bare `at://` address. A link works for
  members and, with the link on, for anyone.
- **Opening one:** the Mac app (`CFBundleURLTypes`: a window with Add to My Drive and
  Download…), `atdrive open-share <link>`, or `atdrive get <link>` to download
  once (signed out for a public link). `atdrive sync --install` makes ATDrive the
  `x-scheme-handler/atdrive` on a Linux desktop.
- **A link to another app's space** says so; the Spaces folder (#28) shows those (`spaces.include`).
- **Clickability:** many email and chat apps don't make `atdrive://` links clickable. If that's a
  real problem, the smallest fix is one static redirect page (the key stays in the fragment).

### Finder

- **Right-click actions** (File Provider custom actions, by each item's `userInfo.sharing`):
  Share…, Copy Link, Stop Sharing. The extension can't show UI, so it hands each to the menu-bar
  app through the App Group container and a Darwin notification (`SharingRequest`).
- **Badges:** `Sharing` decorations on your shares and on those shared with you.
- **The Share window** (menu-bar app): people (with verified / unencrypted-drive / changed-key
  notes), adding and removing them, and the link.

### Lexicons and scope

- **Records:** `mount` as a node and version kind; `shared` as a change; `sharingKey` and `name`
  in `settings`; `member`, `link` and `contact` in the drive space type's collections;
  `shareKey` in the public repo.
- **Scope:** your drive spaces (read, write ATDrive's collections, `manage=create/update/delete`),
  other accounts' drive spaces read-only (`authority=*&action=read`), and `repo:` the share key.
  Naming the space type needs its lexicon published (the PDS resolves it for the consent
  screen), so until then the scope uses `space:*`, which the consent screen warns about.
  `atdrive dev lexicons publish` writes the schema records; then the DNS TXT record, then
  `OAuthLogin.lexiconsPublished`.

### Later

- **Editing together (#25):** several writers' repos in one space; the tree is the union over
  `listWriters`, and `ConflictRules` settles races between people as between devices.
- **`x-callback-url` actions (#31).**
- **Write notifications** (`authorizeSpaceSync`'s `notify`) need an HTTPS endpoint: ATDrive polls.

## Spaces

What's in every space you're in (#28), as a read-only folder at the top of the drive:
`SpaceData` reads it, `SpaceTree` lays it out as files, and `SpacesFolder` (in `Mounts.swift`)
puts it in the joined drive, so the CLI, a synced folder and Finder all show it like the rest of
the drive.

- **Where it comes from:**
  1. `listSpaces` on your PDS: the spaces you own or wrote to, with your repo's revision in each.
     Your own repos are read with your session (`listRecords` with no collection).
  2. Everyone else's: a credential from the space's host (`SpaceCredentials`, as for shares),
     `listWriters` there, then each writer's repo at their PDS with that credential.
  3. Spaces shared with you that you never wrote to: `listSpaces` doesn't list them, and nothing
     else does (#56), so they're named in `spaces.include` in config.toml. `spaces.exclude` hides
     any space (found by itself or included): it's listed, never read. Both are addresses
     (`at://<handle or DID>/space/<type>/<key>`), resolved to URIs once per process.
- **Not shown:** ATDrive's own drive spaces (any `app.atdrive.drive`): they're the drive.
- **Layout:** `<app>/<space>/<record type>/<record>.json`, blobs in `<record>.blobs/`.
  - The app folder is per space type: its declaration's `title` (`resolveLexicon` on your PDS),
    else the last part of the type's domain, capitalized (`my.bulletin.board` → `Bulletin`).
    Types that would share a name get their last segment added, or failing that their whole NSID
    with spaces for dots. Never a dot of ours: Finder takes what follows one for an extension,
    and hides it (`bulletin.my` showed as `bulletin`).
  - Spaces are named by key; someone else's start with `@<owner handle> `.
  - Record types drop the space type's authority (`my.bulletin.note` → `note`); ones from
    another domain keep their full NSID.
  - Records are `<rkey>.json`; someone else's start with `@<handle> `, so each person's sort
    together (a record key is unique only within one account's records).
  - Blobs whose CID isn't sha2-256 (none of atproto's) are left out: every file has a SHA-256
    (`SpaceTree.Item.sha256`, a blob's from its CID), which downloads are checked against and a
    synced folder compares by.
- **In the drive:** the folder's node is `SpacesFolder.id` (`#spaces`: `#` is never in a record
  key), and its items are `#spaces/<item ID>`, so `NodeID.split` puts them in a "mount" no space
  is. `JoinedDrive` reads their contents from `SpaceData` and refuses every write in it
  (`ATDriveError.inSpaces`). Its name is `spaces.folder`, numbered if a folder of yours has it.
  Its nodes' `cid`s change whenever anything shown about them does (contents, name, badge,
  date), which is what Finder's enumerators compare, and the joined anchor includes the folder's
  name; a folder's date is the newest of what's in it. It's read again at most every
  `JoinedDrive.spacesReuse` (5 s), so Finder asking for an item
  and then its folder costs one read. If it can't be read, what was read before stays; never
  read, it's an unreadable node, so nothing in it is taken for deleted.
- **Read-only, and always what's on the server:** a synced folder treats it as a read-only
  folder whose root is locked too (`ReadOnlyFolders`, with no copies kept): what's edited,
  added, deleted, moved or renamed there is put back at the next sync. Finder gives its items
  read-only capabilities (`SharingRole.spaces`), and no sharing actions.
- **Refreshing:** a repo whose revision (`repoRev`, or the writer's from `listWriters`) hasn't
  moved is reused. One that moved follows `listRepoOps` from the last revision; a gap (an op whose
  `prev` isn't what's held, or a value never seen) lists it again in full.
- **Unreadable spaces:** `AppNotAuthorized`, `SpaceNotFound` and the like keep your own records
  and drop everyone else's; the space's folder is marked (`SpaceTree.Item.unreadable`): a badge
  in Finder, the reason in `atdrive spaces`. Network trouble keeps what was read last time.
  Losing access only removes a read-only copy, so nothing is held back for it.
- **Item IDs** are built from the space type, space URI, DID, collection and rkey, so they
  survive handle and title changes.
- **Scope:** `space:*?authority=*&action=read` (`OAuthLogin.spacesScope`). The broad scope already
  includes it; with the narrow one it's asked for only when `spaces.enabled` is on.
- **On a Mac:** the extension can't read config.toml, so the app passes `spaces.*` on through the
  App Group's defaults (`SpacesShare`). Spotlight is off by default (`spaces.spotlight`): items
  carry `com.apple.metadata:kMDItemSupportFileType = MDSystemFile`, which keeps them out of
  Spotlight's results. It's deprecated and undocumented, so check it on a real Mac.

## Protocol notes (alpha, as of 2026-11-17)

- **Reference implementation:** `bluesky-social/atproto`, branch `permissioned-data-alpha`.
  Bluesky updates the hosted PDS on Thursdays.
- **Limits:**
  - Records: at most 1 MiB.
  - `applyWrites`: at most 200 writes.
  - Blobs: the hosted alpha advertises a 300 MB limit, while the PDS default is 5 MB.
- **Auth and privacy:**
  - **OAuth is how you sign in.** It's implemented here: PAR + PKCE + DPoP, a loopback client
    ID, and a redirect to 127.0.0.1. Spaces refuse app passwords.
  - **Naming a space type in a scope** (`space:app.atdrive.drive?…`) makes the PDS
    resolve that type's lexicon for the consent screen. If the lexicon can't be resolved, the
    sign-in fails with `invalid_scope: Unable to retrieve space declarations`.
  - **So ATDrive asks for `space:*`** until its lexicons are published:
    1. `atdrive dev lexicons publish <handle>` writes the `com.atproto.lexicon.schema` records.
    2. Add the DNS TXT record it prints: `_lexicon.atdrive.app` → `did=<that account's DID>`.
    3. Set `OAuthLogin.lexiconsPublished`, which switches to `narrowScope`.
  - **Public OAuth clients get two-week sessions** on Bluesky's PDS, so you sign in again after
    that.
  - Spaces are **not** end-to-end encrypted.
- **No compare-and-swap** on space writes, so conflict detection has to happen on the client.
  Creates do fail if the record exists (`RecordAlreadyExists`).
- **Change feed:** `listRepoOps(since:)` lists writes after a revision. Since 2026-11-12 every
  page carries the current commit (with its MAC), and the feed ends at the page with no cursor.
  See *Storage v2*.
- **Checked against the 2026-11-12 migration guide** (`alpha-migrations/prompt-11-12-26.md`):
  that paging change was the only one ATDrive needed.

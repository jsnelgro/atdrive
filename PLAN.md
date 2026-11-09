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
    found by diffing tree snapshots held in memory. A file that changed remotely during an edit
    gets a conflicted copy.
  - **Not yet exercised:** rename, move and delete from Finder; conflicted copies; large files.
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
    Uploading only the changed chunks of an edited file. Several transfers at once.
- [ ] **Phase 4, iOS:** the same extension code with an iOS host app.
- [ ] **Later:**
  - Publish the lexicons and narrow the OAuth scope (see below).
  - Shared folders (`memberspace`).
  - Client-side encryption.
  - Parallel transfers.

## Folder sync

`FolderSync` (in `Sources/ATDriveCore/Sync/`) runs in passes: on a local change (inotify), and
every 30 seconds to check the drive (`getLatestCommit`; the tree is listed only when the revision
moved).

- **Three-way merge, by node ID.** `.atdrive/state.json` in the folder records what the last pass
  left in agreement: each node's parent, name, hash, and the local file's `lstat`. Each side is
  compared with it, so "deleted here" and "new on the drive" can be told apart. Local items keep
  their node ID by path, then by inode (renames and moves, including whole folders), then by hash
  (copied and deleted, e.g. across disks). Files are read only when their `lstat` changed.
- **Rules** (`SyncPlan`): a change on one side is applied to the other. A file edited on both sides
  keeps the drive's version, and the local one becomes a conflicted copy. Moved on both sides: the
  drive's move wins. Deleted on one side but edited on the other: kept. A folder is kept if
  anything kept is inside it. Two things with one name: one is renamed, unless they're the same
  (a folder, or a file with the same hash), in which case they're paired up. A first sync is
  just this, starting from an empty state.
- **Applying** (`SyncRun`): local moves go through `.atdrive/staging` (with a journal, so a killed
  pass is recovered), so swaps and moves into new folders work. Then the drive is updated, then
  files are downloaded to `.atdrive/downloads` and renamed into place. Nothing local is
  overwritten or deleted if its `lstat` changed since the folder was listed; it's left for the next
  pass. Only items that got all the way through are saved as agreed, so an interrupted pass picks
  up where it left off (and an interrupted conflict doesn't make two copies).
- **Guards:** it stops if the folder or `.atdrive` disappears, refuses a folder synced with
  another account, and takes a lock so only one sync runs per folder. Files changed in the last
  couple of seconds wait (they may still be being written).

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

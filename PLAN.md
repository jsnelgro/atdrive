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
    Uploading only the changed chunks of an edited file. Several transfers at once.
- [x] **Encryption at rest, unlocked with a passkey.** See *Encryption* below.
  - **Tested** with unit tests against `FakePDS` (including a full sign-in in the browser and by
    pasted addresses), and the unlock page in Chromium with a virtual passkey that supports PRF.
  - **Not yet exercised:** a real passkey provider (iCloud Keychain, Google Password Manager,
    1Password), the hosted page, the Mac app's sign-in, and the live alpha PDS.
- [ ] **Phase 4, iOS:** the same extension code with an iOS host app.
- [ ] **Next, in this order.** Each is its own PR, and each adds as few commands as possible:
  1. **Incremental sync:** follow the spaces change feed (`listRepoOps`) instead of re-listing the
     drive. Invisible to users. PR #7 has a version of this to take from.
  2. **A second way in:** add another passkey from a device that's unlocked, and an optional
     recovery key to print, offered in settings rather than at setup.
  3. **History,** if it's still wanted after 1 and 2. Keep it to the Dropbox/iCloud model: `rm`
     moves to a 30-day "recently deleted", `restore` brings back a deleted item or an earlier
     version, and old versions are cleaned up automatically. No `prune`, `purge` or `trash empty`
     commands. Until then, the synced folder is ordinary files, so Time Machine or restic give
     history.
- [ ] **Later:**
  - Publish the lexicons and narrow the OAuth scope (see below).
  - Shared folders (`memberspace`).
  - Parallel transfers.
  - Native passkeys in the Mac app (`ASAuthorizationPlatformPublicKeyCredentialProvider` with PRF,
    which needs an associated domain), instead of the browser page.

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
  permanent. Readable fields: `keyID`, and `chunks: [blob]` for files. Everything else is in
  `sealed` (see *Encryption*):
  - `parent`: rkey, absent for the top level
  - `name`, `kind`, `createdAt`
  - files only: `size`, `sha256`, `modifiedAt`, and the chunks' CIDs
- **The drive key, wrapped:** `me.jsnelgro.atdrive.key`, one record per passkey (the first is
  rkey `first`).
- **File contents:** 4 MiB chunks, each encrypted, uploaded with `com.atproto.repo.uploadBlob` and
  read back with `com.atproto.space.getBlob`. Every chunk is verified against its CID, and the
  whole file against its SHA-256.
- **Damaged trees:** a node whose parent was deleted, and a cycle created by concurrent moves,
  are both shown at the top level, so nothing is ever hidden.

## Encryption

**Goal:** whoever runs the PDS can't read the drive, and nobody has to manage a key.

**Why a passkey.** Signing in to the PDS can't be what unlocks the drive: anything the PDS lets
you fetch, its operator can fetch too. So the drive key needs a secret the PDS never sees, and a
passkey is one that people already have, that syncs between their devices on its own, and that
providers already back up. WebAuthn's PRF extension turns a passkey into 32 secret bytes, the
same every time.

- **Keys:**
  - **The drive key:** 32 random bytes, made on the first sign-in. HKDF-SHA256 derives a records
    key and a contents key from it.
  - **On the PDS**, it's only stored wrapped: AES-256-GCM under HKDF(the passkey's PRF output). The
    PRF input is SHA-256("atdrive drive key v1\n" + DID). These must never change.
  - **On each device**, it's saved with the session (`Session.driveKey`), so the sync service and
    the Finder extension don't need the passkey.
- **What's sealed:** each node record's name, folder, kind, size, hash, times and chunk CIDs (bound
  to its space, collection and rkey, so the PDS can't move it to another record). Every chunk is
  encrypted too, with a random nonce. The format is `[0x01][nonce 12][ciphertext][tag 16]`.
- **What the PDS still sees:** record counts, chunk counts and sizes (so roughly file sizes),
  creation times (TIDs), and when writes happen. It can delete or roll back records, but can't
  read or forge them.
- **Signing in** (`SignIn`, `DriveUnlock`):
  1. OAuth, as before. The browser comes back to the app on 127.0.0.1.
  2. The app looks at the drive: no key record means "create", otherwise "unlock" with the
     passkeys that have one. It answers the browser's request with a redirect to the unlock page.
  3. The unlock page (`web/unlock/`, static, no network requests of its own) runs the passkey
     ceremony and redirects back to 127.0.0.1 with the PRF output, sealed to a one-time P-256 key
     the app put in the page's URL fragment (ECDH, HKDF, AES-GCM, bound to `state`). So it's
     unreadable in browser history and in a pasted address.
  4. The app creates the drive key and writes its key record (create-if-absent, so two devices
     setting up at once can't make two keys), or unwraps it.
  - **Remote machines** paste the address the browser ends up on, as for OAuth, at each step.
  - **The page only returns to a loopback address,** so a link can't send the secret elsewhere.
- **Guards:**
  - A record this device can't decrypt (another key, tampered, or a newer format) makes listing
    the drive fail, rather than leaving the item out: sync and Finder would take a missing item as
    deleted and delete their copy.
  - A new key is never made for a drive that has encrypted items, even if its key record is gone.
- **Drives from before encryption:** signing in encrypts them in place (`Drive.encryptOlderItems`):
  each item's chunks are uploaded again encrypted, and its record is sealed, one item at a time.
- **Trust in the page:** its JavaScript sees the PRF output, so it must come from a host we
  control (`https://atdrive.jsnelgro.me/unlock/`, served from `web/`). Passkeys belong to that host
  name, so it can't change without making new passkeys.
- **Open:**
  - One passkey per drive (step 2 of *Next* in *Status*).
  - Removing a device doesn't change the key; it just deletes its session. A device that had
    the key keeps it.

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
  - Spaces are **not** end-to-end encrypted. ATDrive encrypts on the device (see *Encryption*).
- **No compare-and-swap** on space writes, so conflict detection has to happen on the client.

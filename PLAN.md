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
  - Unit tests pass on Linux (Swift 6.4.2).
  - CLI smoke-tested against an in-memory fake PDS.
  - Login checked against the live alpha PDS (handle → DID → PDS → `createSession`).
  - Builds and passes tests on macOS too (CI).
  - **Not yet run against the live alpha:** the full upload/download round trip (`LiveTests`
    needs an app password).
- [ ] **Phase 2, macOS File Provider** (written, **not yet run on a Mac**):
  - A menu-bar host app plus an `NSFileProviderReplicatedExtension`, assembled by
    `scripts/build-app.sh` without an .xcodeproj.
  - Sync anchor = repo revision (`getLatestCommit`). Changes are found by diffing tree snapshots
    held in memory.
  - Conflicted copies when a file changed remotely during an edit.
  - To verify on a real Mac: domain registration and signing (whether a provisioning profile
    is needed), placeholder downloads, uploads, rename/move/delete, remote changes appearing
    via polling.
  - Next: persist snapshots across extension restarts, push instead of polling, upload/download
    progress in Finder.
- [ ] **Phase 3, Linux:** `atdrive mount <dir>` over FUSE (libfuse3 via a C module).
- [ ] **Phase 4, iOS:** the same extension code with an iOS host app.
- [ ] **Later:** OAuth with `space:` scopes, shared folders (`memberspace`), client-side
  encryption, parallel transfers.

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

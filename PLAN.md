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
  - **Not yet run against the live alpha:** the full upload/download round trip (`LiveTests`
    needs an app password), and the macOS build (CI is set up for it).
- [ ] **Phase 2, macOS File Provider:** a menu-bar host app plus an
  `NSFileProviderReplicatedExtension`, built on `ATDriveCore`. Bundles get assembled with
  scripts in the style of swift-mac-app-template, so no .xcodeproj.
  - Needs: a local metadata cache, a change feed (`listRepoOps(since:)`) feeding sync anchors,
    polling `getLatestCommit`, and conflict copies.
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
  - App-password (Bearer) sessions work on every space endpoint.
  - OAuth needs `space:` scopes, which no Swift library supports yet.
  - Spaces are **not** end-to-end encrypted.
- **No compare-and-swap** on space writes, so conflict detection has to happen on the client.

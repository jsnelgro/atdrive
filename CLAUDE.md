# ATDrive

A Dropbox-style drive stored in atproto spaces (permissioned data, alpha). Pure Swift: one
SwiftPM package, no .xcodeproj. Builds and runs on macOS and Linux.

## Commands

- `scripts/test.sh`: unit tests (`--filter Name` to run some). `LiveTests` runs only with
  `ATDRIVE_LIVE_HANDLE` and `ATDRIVE_LIVE_PASSWORD` set, and hits a real PDS.
- `scripts/build.sh`: release binary at `build/atdrive`. The Swift runtime is static on Linux.
- `scripts/format.sh`: formatting (config in `.swift-format`).

## Layout

- `Sources/ATDriveCore`: everything except the CLI, so the macOS/iOS File Provider extension and
  the Linux FUSE mount can reuse it later.
  - `XRPC.swift`, `Session.swift`: HTTP API client, token refresh, login.
  - `Identity.swift`: handle → DID → PDS. Never hardcode a PDS or account.
  - `Spaces.swift`: **every** `com.atproto.space.*` call. The alpha API changes weekly, so keep it
    contained here.
  - `Records.swift`, `Lexicon.swift`: the `me.jsnelgro.atdrive.*` record model (matches `lexicons/`).
  - `DriveTree.swift`: in-memory tree and path lookup. `Drive.swift`: upload, download, move, delete.
- `Sources/atdrive`: the CLI (swift-argument-parser). Commands are thin; logic belongs in the core.
- `Tests/ATDriveCoreTests`: Swift Testing. `FakePDS` is an in-memory transport for drive-logic
  tests.
- `lexicons/`: schemas for our NSIDs. Update them together with `Records.swift`.

## Conventions

- Swift 6 language mode (strict concurrency). Prefer value types, `async`/`await` and actors.
  No Combine.
- Code shared with Linux must avoid Apple-only frameworks. Use `#if canImport(FoundationNetworking)`
  for networking types. Anything AppKit/FileProvider goes in separate, platform-gated targets.
- Reference implementation for the spaces protocol: `bluesky-social/atproto`, branch
  `permissioned-data-alpha` (lexicons in `lexicons/com/atproto/space/`).

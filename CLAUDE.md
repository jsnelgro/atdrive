# ATDrive

A Dropbox-style drive stored in atproto spaces (permissioned data, alpha). Pure Swift: one
SwiftPM package, no .xcodeproj. The CLI runs on macOS and Linux. The Finder integration
(menu-bar app + File Provider extension) is macOS only.

## Commands

- `scripts/test.sh`: unit tests (`--filter Name` to run some). They hit a real PDS only when
  enabled: `OAuthLiveTests` with `ATDRIVE_LIVE_HANDLE`, and `LiveTests` with that plus
  `ATDRIVE_LIVE_PASSWORD`.
- `scripts/build.sh`: release binary at `build/atdrive`. The Swift runtime is static on Linux.
- `scripts/format.sh`: formatting (config in `.swift-format`).
- `scripts/build-app.sh` / `scripts/run-app.sh` (macOS): build `build/ATDrive.app` (and install
  and launch it). Signing needs an Apple Development certificate; `ALLOW_ADHOC=1` builds
  without one (it can't add the drive to Finder).

## Layout

- `Sources/ATDriveCore`: everything except the CLI, so the macOS/iOS File Provider extension and
  the Linux FUSE mount can reuse it later.
  - `XRPC.swift`, `Session.swift`: HTTP API client; `SessionManager` signs requests (Bearer, or
    DPoP for OAuth), tracks DPoP nonces and refreshes tokens.
  - `OAuth.swift`, `DPoP.swift`, `LoopbackServer.swift`: atproto OAuth sign-in (PAR + PKCE +
    DPoP, loopback client ID, browser redirect caught on 127.0.0.1). The default. App-password
    login (`Auth.login`) is kept for scripts and tests.
  - `Identity.swift`: handle → DID → PDS. Never hardcode a PDS or account.
  - `Spaces.swift`: **every** `com.atproto.space.*` call. The alpha API changes weekly, so keep it
    contained here.
  - `Records.swift`, `Lexicon.swift`: the `me.jsnelgro.atdrive.*` record model (matches `lexicons/`).
  - `DriveTree.swift`: in-memory tree and path lookup. `Drive.swift`: upload, download, move, delete.
- `Sources/atdrive`: the CLI (swift-argument-parser). Commands are thin; logic belongs in the core.
- `Sources/Mac` (targets added in Package.swift only `#if os(macOS)`, Swift 5 language mode):
  - `FileProvider/`: `NSFileProviderReplicatedExtension`. `DriveIndex` caches trees by repo
    revision, and the revision is the sync anchor; enumerators diff snapshots. `main.swift` calls
    `NSExtensionMain` (declared in `CExtensionMain/`) because SwiftPM can't build an .appex.
  - `App/`: SwiftUI `MenuBarExtra`. Signs in, adds the File Provider domain, polls with
    `signalEnumerator`.
  - `Support/`: shared by both. App Group container (the ID comes from Info.plist
    `ATDriveAppGroup`, filled in at build time) and the domain.
- `Resources/{App,FileProvider}`: Info.plists and entitlements templates (`__BUNDLE_ID__`,
  `__APP_GROUP__`).
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

# ATDrive

A Dropbox-style drive stored in atproto spaces (permissioned data, alpha). Pure Swift: one
SwiftPM package, no .xcodeproj. The CLI runs on macOS and Linux. The Finder integration
(menu-bar app + File Provider extension) is macOS only.

## Commands

- **No `swift` on PATH (Linux sandbox)?** Run `scripts/setup-swift.sh`, then source the file it
  names (`. ~/.swift/env.sh`). Don't hunt for another way to install Swift. It installs the
  newest release of the series CI uses (6.4) from `download.swift.org`. If that host isn't
  reachable (the sandbox's network allowlist), it falls back to Swift 6.0.3 from Ubuntu's
  package archive and holds swift-crypto at 4.x in a local-only change that git ignores.
  Everything builds and the tests pass that way, but CI is the real check, and
  `scripts/setup-swift.sh --undo` must run before a real change to `Package.swift`. Swift
  Testing on 6.0 can't take `try` inside `#expect(...)`: compute the value first.
- `scripts/test.sh`: unit tests (`--filter Name` to run some), run twice: the drive-logic suites
  on a plain drive, then on an encrypted one (`ATDRIVE_TEST_MODE=plain` or `=encrypted` runs one;
  `TestMode` in `FakePDS.swift`). Anything about how the drive behaves has to pass on both. They
  hit a real PDS only when enabled: `OAuthLiveTests` with `ATDRIVE_LIVE_HANDLE`, the others with
  `ATDRIVE_LIVE_STATE` (and `ATDRIVE_LIVE_STATE_B`, a second account, for sharing): a folder
  `ATDRIVE_STATE_DIR=<folder> atdrive login <handle>` saved a session to.
- `scripts/build.sh`: release binary at `build/atdrive`. The Swift runtime is static on Linux.
- `scripts/format.sh`: formatting (config in `.swift-format`).
- `scripts/build-app.sh` / `scripts/run-app.sh` (macOS): build `build/ATDrive.app` (and install
  and launch it). Signing needs an Apple Development certificate; `ALLOW_ADHOC=1` builds
  without one (it can't add the drive to Finder).

## Layout

- `Sources/ATDriveCore`: everything except the CLI, so the macOS/iOS File Provider extension and
  the Linux synced folder can reuse it.
  - `XRPC.swift`, `Session.swift`: HTTP API client; `SessionManager` signs requests (DPoP),
    tracks DPoP nonces and refreshes tokens. A client made with `SpaceCredentials` reads another
    account's space instead (`SpaceCredentials.swift`: delegation token, credential, request
    signatures and commit MACs; the primitives are in `Crypto/SpaceAuth.swift`).
  - `OAuth.swift`, `DPoP.swift`, `LoopbackServer.swift`: atproto OAuth sign-in (PAR + PKCE +
    DPoP, loopback client ID, browser redirect caught on 127.0.0.1). The only way to sign in:
    atproto spaces refuse app passwords.
  - `Identity.swift`: handle → DID → PDS. Never hardcode a PDS or account.
  - Kept on this machine: secrets (the session, the device's key) in `SecretStorage.swift` (the
    login Keychain for `atdrive` on a Mac; the App Group container for the Mac app and the
    `atdrive` inside it; on Linux the Secret Service through `secret-tool`, in `SecretService.swift`,
    or files in `$XDG_STATE_HOME/atdrive` where there's none), read through `SessionStore.swift`. Several processes share a
    session (app, extension, CLI): make every `SessionManager` for a saved session with
    `store:`, so refreshing holds the store's lock and takes tokens another process refreshed to
    (a refresh token works once); and settings in `config.toml` (`Config.swift`, with
    the TOML subset in `TOML.swift`), shared by the CLI and the Mac app. **Never put a secret in
    `config.toml` or `~/.config`**: people keep that in version control. The drive's own settings
    are a record in the drive (`DriveSettings`), not local config.
  - `Spaces.swift`: **every** `com.atproto.space.*` call. The alpha API changes weekly, so keep it
    contained here.
  - `Records.swift`, `Lexicon.swift`: the `me.jsnelgro.atdrive.*` record model (matches `lexicons/`).
  - `DriveTree.swift`: in-memory tree and path lookup. `Drive.swift`: upload, download, move, delete.
    One `Drive` is one space; a drive made of several spaces (shared folders) is several of them.
  - `Mounts.swift`: `JoinedDrive` / `JoinedSnapshot`, the home drive with the spaces mounted in
    it, as one tree. Node IDs are the home record key, or `<mount>/<rkey>` (`NodeID`). Sync, the
    CLI's file commands and the Mac extension all use it. A mount that can't be read is held,
    never taken for empty.
  - Sharing: `Sharing.swift` (share, unshare, ending sharing when encryption switches),
    `Links.swift` (links, opening them), `People.swift` (members, the account's sharing key),
    `ShareKeys.swift` (member and link records), `Verification.swift` (verification codes).
    `Reset.swift`: `atdrive dev reset`.
  - `SpaceData.swift`: the spaces view (#28): every space the account is in, of any app,
    read-only (`SpaceData` reads it, `SpaceTree` lays it out as files, by app, space and record
    type). The CLI's `atdrive spaces` and the Mac extension's second domain
    (`Mac/FileProvider/SpacesLocation.swift`) show it. Off unless `spaces.enabled`.
  - `StoredRecords.swift`: the **only** place records become stored values and back. A record is
    plain or sealed and says which; `Drive.mode` (from the settings record) picks the form for
    writes. `DriveKeys.swift`: opening a drive, keys, devices. `Encryption.swift`: turning
    encryption on and off, and converting what's there. `Crypto/`: the primitives. The formats
    are specified in `docs/FORMAT.md` (for other clients, e.g. a web app): change them together,
    with the vectors in `CryptoVectorTests`.
  - `ConflictRules.swift`: what happens when something changed in two places (edits, moves,
    deletes, deleted folders). **Both** `SyncPlan` and the Mac extension decide with it, so the
    platforms agree; change the rules there, not in either caller. `ConflictName.swift`: copy names.
  - `Sync/`: two-way folder sync (`atdrive sync`, the Linux "drive folder"). `SyncPlan` is the pure
    three-way merge (last agreed state vs. folder vs. drive, keyed by node ID); `FolderSync` /
    `SyncRun` apply it with POSIX calls; `FolderWatcher` is inotify. See PLAN.md, "Folder sync".
- `Sources/atdrive`: the CLI (swift-argument-parser). Commands are thin; logic belongs in the core.
- `Sources/Mac` (targets added in Package.swift only `#if os(macOS)`, Swift 5 language mode):
  - `FileProvider/`: `NSFileProviderReplicatedExtension`. `DriveIndex` caches trees by repo
    revision, and the revision is the sync anchor; enumerators diff snapshots. It's a dynamic
    library: an extension executable must have no `main` (the extension runtime calls `main` if
    present, so a main that starts the extension recurses until it crashes), and SwiftPM always
    gives executables one. `build-app.sh` links a code-free executable with `-e _NSExtensionMain`
    that loads the library, as Xcode does.
  - `App/`: SwiftUI `MenuBarExtra`. Signs in, adds the File Provider domain, polls with
    `signalEnumerator`.
  - `Support/`: shared by both. App Group container (the ID comes from Info.plist
    `ATDriveAppGroup`, filled in at build time) and the domain. `SharingRequests.swift`: how
    Finder's sharing actions reach the app (the extension can't show windows): a request in the
    App Group container plus a Darwin notification. The app's sharing windows and `atdrive://`
    handling are in `App/Sharing.swift`.
- `Resources/{App,FileProvider,CLI}`: Info.plists and entitlements templates (`__BUNDLE_ID__`,
  `__APP_GROUP__`). `build-app.sh` puts the CLI in the app at `Contents/Helpers/atdrive`, signed
  with the App Group, so it shares the app's session and device (`SecretStorage.standard`);
  `App/CommandLineTool.swift` shows how to put it on the PATH.
- `Tests/ATDriveCoreTests`: Swift Testing. `FakePDS` is an in-memory transport for drive-logic
  tests: several accounts (`addAccount`, `as(did)`), spaces with policies and members,
  credentials, MACs, DID documents and public repos.
- `lexicons/`: schemas for our NSIDs. Update them together with `Records.swift`.

## Conventions

- Swift 6 language mode (strict concurrency). Prefer value types, `async`/`await` and actors.
  No Combine.
- Code shared with Linux must avoid Apple-only frameworks. Use `#if canImport(FoundationNetworking)`
  for networking types. Anything AppKit/FileProvider goes in separate, platform-gated targets.
- Git: every change goes on its own branch and lands through a pull request whose description
  says what changed and why. Merge with a merge commit (not squash or fast-forward), so each
  feature stays one chunk in `main`'s history. Open the PR and leave merging to the repo owner
  unless asked to merge.
- Reference implementation for the spaces protocol: `bluesky-social/atproto`, branch
  `permissioned-data-alpha` (lexicons in `lexicons/com/atproto/space/`).

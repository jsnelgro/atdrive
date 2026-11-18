import ATDriveCore
import ATDriveMacSupport
import AppKit
import FileProvider
import Observation
import os

/// The menu-bar app's state. The app itself is small: it signs you in, opens the drive (getting
/// this Mac its keys, if the drive is encrypted), tells macOS about the drive (a File Provider
/// "domain"), and nudges the extension to check for changes. All file transfers happen in the
/// extension.
@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case signedOut
        /// Waiting for the user to approve access in the browser.
        case signingIn
        /// Signed in; opening the drive (with this Mac's keys, if it's encrypted).
        case openingDrive(handle: String)
        /// The account has no drive yet: the user chooses whether to encrypt the one made now.
        case choosingEncryption(handle: String)
        /// An encrypted drive just created: its recovery key, shown until the user says they've
        /// saved it.
        case showingRecoveryKey(handle: String, key: String)
        /// An encrypted drive this Mac has no keys for: approval from another device, or the
        /// recovery key.
        case needsKeys(handle: String)
        case signedIn(handle: String)
    }

    /// While waiting for approval: this Mac's code with a device that has the keys.
    struct PairingLine: Identifiable, Equatable {
        var name: String
        var code: String
        var id: String { name + code }
    }

    private(set) var state: State = .signedOut
    private(set) var busy = false
    private(set) var message: String?
    /// Whether the open drive is encrypted (Settings changes it: `driveModeChanged`).
    private(set) var driveMode: DriveMode?
    /// When the menu last asked Finder to check for changes.
    private(set) var lastChecked: Date?
    var handle = ""

    /// Waiting for another device to approve this Mac, with this Mac's codes.
    private(set) var waitingForApproval = false
    private(set) var pairingCodes: [PairingLine] = []
    /// A keyring that arrived: its sender's code, for the user to compare before it's taken.
    private(set) var arrived: ArrivedKeyring?
    var recoveryKeyText = ""

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var signingIn: Task<Void, Never>?
    @ObservationIgnored private var approval: Task<Void, Never>?
    /// The drive, as this Mac (`DeviceIdentity`), while its keys are being set up.
    @ObservationIgnored private var drive: Drive?
    @ObservationIgnored private var joined: JoinedDrive?
    private let logger = Logger(subsystem: Log.subsystem, category: "app")

    /// This Mac's settings, from `~/.config/atdrive/config.toml` (the CLI's too): read again
    /// before each check for changes, so an edit to the file takes effect without a restart.
    private(set) var config = LocalConfig()
    /// Why config.toml can't be read or saved; the last settings that worked are used meanwhile.
    private(set) var configProblem: String?

    /// The account, once the drive is open.
    var signedInHandle: String? {
        if case .signedIn(let handle) = state { handle } else { nil }
    }

    /// This Mac's name, as other devices list it.
    var deviceName: String { drive?.identity?.name ?? DeviceName.current }

    func start() {
        guard let store = AppGroup.sessionStore() else {
            message = "App Group container unavailable. Build the app with scripts/build-app.sh."
            return
        }
        if let session = try? store.load() {
            state = .openingDrive(handle: session.handle)
            Task { await openDrive(handle: session.handle) }
        }
        startPolling()
    }

    /// Checks the drive for changes made elsewhere every `sync.interval` seconds.
    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.reloadConfig().syncInterval ?? LocalConfig().syncInterval
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.syncNow()
                await self?.pruneIfDue()
            }
        }
    }

    /// Reads config.toml again (the Settings window shows what it says), keeping the last
    /// settings that worked if it can't be read.
    @discardableResult func reloadConfig() -> LocalConfig {
        // Set only when changed: setting an observed property redraws what shows it.
        do {
            let loaded = try UserConfig.file.load()
            if loaded != config { config = loaded }
            if configProblem != nil { configProblem = nil }
        } catch {
            let problem = String(describing: error)
            if problem != configProblem { configProblem = problem }
        }
        return config
    }

    /// Saves it in config.toml, and checks for changes on the new schedule from now.
    func setSyncInterval(_ seconds: Int) {
        guard seconds != config.syncInterval else { return }
        do {
            try UserConfig.file.update { $0.syncInterval = seconds }
            config.syncInterval = seconds
            configProblem = nil
            startPolling()
        } catch {
            configProblem = String(describing: error)
        }
    }

    /// Opens the account's own sign-in page in the browser (OAuth), and finishes when the user
    /// approves there. ATDrive never sees the password.
    func signIn() {
        guard let store = AppGroup.sessionStore(), state == .signedOut else { return }
        message = nil
        state = .signingIn
        let handle = handle
        signingIn = Task {
            do {
                let session = try await OAuthLogin.signIn(identifier: handle) { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                try store.save(session)
                state = .openingDrive(handle: session.handle)
                await openDrive(handle: session.handle)
            } catch is CancellationError {
                state = .signedOut
            } catch {
                message = String(describing: error)
                state = .signedOut
            }
        }
    }

    func cancelSignIn() {
        signingIn?.cancel()
        signingIn = nil
        state = .signedOut
    }

    func signOut() async {
        busy = true
        defer { busy = false }
        approval?.cancel()
        approval = nil
        waitingForApproval = false
        arrived = nil
        drive = nil
        joined = nil
        driveMode = nil
        lastChecked = nil
        do {
            // Keeps a copy of any edits that hadn't finished uploading.
            if let preserved = try await NSFileProviderManager.remove(
                DriveDomain.make(displayName: ""), mode: .preserveDirtyUserData)
            {
                logger.notice("unsynced edits preserved at \(preserved.path, privacy: .public)")
            }
        } catch {
            logger.error("removing domain failed: \(String(describing: error), privacy: .public)")
        }
        // This Mac's device identity stays, so signing in again doesn't need another approval.
        if let store = AppGroup.sessionStore(), let session = try? store.load() {
            await Auth.logout(session)
            try? store.delete()
        }
        state = .signedOut
        message = nil
    }

    // MARK: The drive's keys

    /// Opens the drive. With no drive yet, asks whether to encrypt it (`createDrive`). For an
    /// encrypted drive this Mac has no keys for, asks how to get them. Only the app, never the
    /// extension, creates a drive.
    private func openDrive(handle: String) async {
        let drive: Drive
        do {
            drive = try await makeDrive()
        } catch {
            logger.error("opening the drive's stores failed: \(String(describing: error), privacy: .public)")
            message = String(describing: error)
            state = .signedOut
            return
        }
        self.drive = drive
        do {
            try await drive.open()
            await finishOpening(handle: handle)
        } catch DriveAccessError.noDrive {
            message = nil
            state = .choosingEncryption(handle: handle)
        } catch let error as DriveAccessError {
            if case .notApproved = error {} else { message = error.description }
            state = .needsKeys(handle: handle)
        } catch {
            // Offline, say: carry on, and the extension tries again.
            logger.error("opening the drive failed: \(String(describing: error), privacy: .public)")
            await finishOpening(handle: handle)
        }
    }

    /// The user chose, for a new drive, whether to encrypt it. An encrypted one's recovery key is
    /// shown next.
    func createDrive(encrypted: Bool) {
        guard let drive, case .choosingEncryption(let handle) = state, !busy else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                if let key = try await drive.create(encrypted: encrypted) {
                    state = .showingRecoveryKey(handle: handle, key: key.formatted)
                } else {
                    await finishOpening(handle: handle)
                }
            } catch DriveAccessError.driveExists {
                // Another device made it a moment ago: open that one.
                state = .openingDrive(handle: handle)
                await openDrive(handle: handle)
            } catch {
                message = String(describing: error)
            }
        }
    }

    /// The user has saved the new drive's recovery key.
    func savedRecoveryKey() {
        guard case .showingRecoveryKey(let handle, _) = state else { return }
        Task { await finishOpening(handle: handle) }
    }

    /// Asks for the drive's keys, shows this Mac's codes, and waits for a device to approve it.
    func waitForApproval() {
        guard let drive, let me = drive.identity else { return }
        message = nil
        approval?.cancel()
        approval = Task {
            do {
                if (try? await drive.arrivedKeyring()) == nil { try await drive.requestAccess() }
                var lines: [PairingLine] = []
                for device in try await drive.devices() where device.approved && !device.isThisDevice {
                    lines.append(PairingLine(name: device.name, code: try device.pairingCode(with: me)))
                }
                pairingCodes = lines
                waitingForApproval = true
                while !Task.isCancelled {
                    do {
                        if let keyring = try await drive.arrivedKeyring() {
                            arrived = keyring
                            return
                        }
                    } catch let error as DriveAccessError {
                        message = error.description  // a keyring from a device not in the roster: ignored
                    } catch {
                        // Offline for a moment, say: try again next time.
                    }
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError {
            } catch {
                message = String(describing: error)
                waitingForApproval = false
            }
        }
    }

    /// The user compared the code of the device that approved this Mac.
    func confirmArrived(matches: Bool) {
        guard let drive, let arrived, case .needsKeys(let handle) = state else { return }
        self.arrived = nil
        Task {
            guard matches else {
                message = "Not accepted. Approve this Mac again from a device you trust."
                waitForApproval()
                return
            }
            do {
                try await drive.accept(arrived)
                waitingForApproval = false
                await finishOpening(handle: handle)
            } catch {
                message = String(describing: error)
                waitForApproval()
            }
        }
    }

    func unlockWithRecoveryKey() {
        guard let drive, case .needsKeys(let handle) = state else { return }
        let text = recoveryKeyText
        message = nil
        Task {
            do {
                try await drive.unlock(recoveryKey: try RecoveryKey(parsing: text))
                recoveryKeyText = ""
                approval?.cancel()
                waitingForApproval = false
                arrived = nil
                await finishOpening(handle: handle)
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func finishOpening(handle: String) async {
        message = nil
        driveMode = drive?.mode
        state = .signedIn(handle: handle)
        await addToFinder(handle: handle)
    }

    /// The drive with what's mounted in it, opened, for sharing and settings: `nil` until signed
    /// in. It's the drive the app opened, so there's one copy of this Mac's identity in the app.
    func joinedDrive() async -> JoinedDrive? {
        guard case .signedIn = state else { return nil }
        if let joined { return joined }
        guard let drive = self.drive, (try? await drive.open()) != nil else { return nil }
        let joined = JoinedDrive(
            home: drive, access: SpaceAccess(ownClient: drive.client, resolver: IdentityResolver()))
        self.joined = joined
        return joined
    }

    /// The drive as this Mac: its identity is made the first time, in the App Group container, so
    /// the extension can unlock the drive with it too.
    private func makeDrive() async throws -> Drive {
        guard let store = AppGroup.sessionStore() else { throw StoreProblem.noContainer }
        let session: Session
        do {
            guard let loaded = try store.load() else { throw StoreProblem.noSession(store.storage.description) }
            session = loaded
        } catch let problem as StoreProblem {
            throw problem
        } catch {
            throw StoreProblem.unreadable("the session in \(store.storage)", error)
        }
        let devices = store.devices
        let identity: DeviceIdentity
        do {
            identity = try devices.loadOrCreate()
        } catch {
            throw StoreProblem.unreadable("this Mac's key in \(devices.storage)", error)
        }
        let manager = SessionManager(session) { updated in try? store.save(updated) }
        return await Drive(session: manager, identity: identity) { updated in try? devices.save(updated) }
    }

    /// Why the session or this Mac's keys couldn't be read, said in full.
    enum StoreProblem: Error, CustomStringConvertible {
        case noContainer
        /// Where it should have been.
        case noSession(String)
        /// What couldn't be read, and where.
        case unreadable(String, any Error)

        var description: String {
            switch self {
            case .noContainer:
                "The App Group container is unavailable. Build the app with scripts/build-app.sh."
            case .noSession(let place):
                "Signed in, but no session was saved in \(place). Try signing in again."
            case .unreadable(let what, let error):
                "Couldn't read or write \(what): \(error)"
            }
        }
    }

    func dismissMessage() {
        message = nil
    }

    func driveModeChanged() {
        driveMode = drive?.mode
    }

    // MARK: Finder

    /// Shows the drive in Finder. A sandboxed app can't *open* a folder outside its container
    /// (`NSWorkspace.open` fails with "doesn't have permission"), but it can ask Finder to
    /// reveal one, which is allowed.
    func showInFinder() async {
        guard let manager = DriveDomain.manager else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = "Couldn't show the drive: \(error.localizedDescription)"
        }
    }

    /// Asks the extension to check the drive for changes made elsewhere (other devices, the CLI).
    func syncNow() async {
        guard case .signedIn = state, let manager = DriveDomain.manager else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
            lastChecked = Date()
        } catch {
            logger.error("signal failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes history older than the drive keeps, once a day, as `atdrive sync` does: nothing
    /// else on a Mac does it. The day is counted from the last try, so a failure waits a day too.
    private func pruneIfDue() async {
        let key = "lastPruned"
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: key) as? Date, last <= now,
            now.timeIntervalSince(last) < 24 * 60 * 60
        {
            return
        }
        guard let joined = await joinedDrive() else { return }
        UserDefaults.standard.set(now, forKey: key)
        do {
            let snapshot = try await joined.update(nil)
            let removed = try await joined.prune(snapshot, now: now)
            logger.notice("pruned \(removed) old versions")
            if removed > 0 { await syncNow() }
        } catch {
            logger.error("pruning failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func addToFinder(handle: String) async {
        do {
            // macOS names the folder "ATDrive-<display name>" and shows the name in the sidebar.
            try await NSFileProviderManager.add(DriveDomain.make(displayName: handle))
        } catch {
            message = "Couldn't add ATDrive to Finder: \(error.localizedDescription)"
            logger.error("adding domain failed: \(String(describing: error), privacy: .public)")
        }
    }
}

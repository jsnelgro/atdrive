import ATDriveCore
import ATDriveMacSupport
import AppKit
import FileProvider
import Observation
import os

/// The menu-bar app's state. The app itself is small: it signs you in, gets this Mac the drive's
/// keys (the drive is encrypted), tells macOS about the drive (a File Provider "domain"), and
/// nudges the extension to check for changes. All file transfers happen in the extension.
@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case signedOut
        /// Waiting for the user to approve access in the browser.
        case signingIn
        /// Signed in; opening the drive with this Mac's keys.
        case openingDrive(handle: String)
        /// A drive just created: its recovery key, shown until the user says they've saved it.
        case showingRecoveryKey(handle: String, key: String)
        /// A drive this Mac has no keys for: approval from another device, or the recovery key.
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
    private let logger = Logger(subsystem: Log.subsystem, category: "app")

    /// How often to check the drive for changes made elsewhere.
    private let pollInterval: Duration = .seconds(30)

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
        polling = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.syncNow()
            }
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

    /// Opens the drive with this Mac's keys. With no drive yet, creates it and shows its recovery
    /// key; for a drive this Mac has no keys for, asks how to get them. Only this, never the
    /// extension, creates a drive: it has a recovery key to show.
    private func openDrive(handle: String) async {
        guard let drive = await makeDrive() else {
            message = "Couldn't read this Mac's keys from the App Group container."
            state = .signedOut
            return
        }
        self.drive = drive
        do {
            try await drive.unlock()
            await finishOpening(handle: handle)
        } catch DriveAccessError.noDrive {
            do {
                let key = try await drive.create()
                state = .showingRecoveryKey(handle: handle, key: key.formatted)
            } catch DriveAccessError.driveExists {
                state = .needsKeys(handle: handle)  // another device made it a moment ago
            } catch {
                message = String(describing: error)
                state = .needsKeys(handle: handle)
            }
        } catch let error as DriveAccessError {
            if case .notApproved = error {} else { message = error.description }
            state = .needsKeys(handle: handle)
        } catch {
            // Offline, say: carry on, and the extension tries again.
            logger.error("opening the drive failed: \(String(describing: error), privacy: .public)")
            await finishOpening(handle: handle)
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
        state = .signedIn(handle: handle)
        await addToFinder(handle: handle)
    }

    /// The drive as this Mac: its identity is made the first time, in the App Group container, so
    /// the extension can unlock the drive with it too.
    private func makeDrive() async -> Drive? {
        guard let store = AppGroup.sessionStore(), let session = try? store.load(),
            let devices = AppGroup.deviceStore(), let identity = try? devices.loadOrCreate()
        else { return nil }
        let manager = SessionManager(session) { updated in try? store.save(updated) }
        return await Drive(session: manager, identity: identity) { updated in try? devices.save(updated) }
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
        } catch {
            logger.error("signal failed: \(String(describing: error), privacy: .public)")
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

import ATDriveCore
import ATDriveMacSupport
import AppKit
import FileProvider
import Observation
import os

/// The menu-bar app's state. The app itself is small: it signs you in, tells macOS about the
/// drive (a File Provider "domain"), and nudges the extension to check for changes. All file
/// transfers happen in the extension.
@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case signedOut
        /// Waiting for the user to approve access in the browser.
        case signingIn
        case signedIn(handle: String)
    }

    private(set) var state: State = .signedOut
    private(set) var busy = false
    private(set) var message: String?
    var handle = ""

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var signingIn: Task<Void, Never>?
    private let logger = Logger(subsystem: Log.subsystem, category: "app")

    /// How often to check the drive for changes made elsewhere.
    private let pollInterval: Duration = .seconds(30)

    func start() {
        guard let store = AppGroup.sessionStore() else {
            message = "App Group container unavailable. Build the app with scripts/build-app.sh."
            return
        }
        if let session = try? store.load() {
            if session.driveKey != nil {
                state = .signedIn(handle: session.handle)
                Task { await addToFinder(handle: session.handle) }
            } else {
                // Saved before drives were encrypted.
                handle = session.handle
                message = "Sign in again to unlock your drive."
            }
        }
        polling = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.syncNow()
            }
        }
    }

    /// Opens the account's own sign-in page in the browser (OAuth), then the passkey page that
    /// unlocks the drive, and finishes when the user has done both. ATDrive never sees the
    /// password, and the PDS never sees the drive's key.
    func signIn() {
        guard let store = AppGroup.sessionStore(), state == .signedOut else { return }
        message = nil
        state = .signingIn
        let handle = handle
        signingIn = Task {
            do {
                let session = try await SignIn.run(identifier: handle) { url, step in
                    // After the sign-in page, the browser goes on to the unlock page by itself.
                    guard step != .unlock(alreadyOpen: true) else { return }
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                try store.save(session)
                // Drives from before encryption: encrypt what's there now.
                let manager = SessionManager(session) { updated in try? store.save(updated) }
                try await Drive(session: manager).encryptOlderItems()
                state = .signedIn(handle: session.handle)
                await addToFinder(handle: session.handle)
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
        if let store = AppGroup.sessionStore(), let session = try? store.load() {
            await Auth.logout(session)
            try? store.delete()
        }
        state = .signedOut
        message = nil
    }

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

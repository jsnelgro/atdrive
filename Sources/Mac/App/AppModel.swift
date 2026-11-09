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
        case signedIn(handle: String)
    }

    private(set) var state: State = .signedOut
    private(set) var busy = false
    private(set) var message: String?
    var handle = ""
    var password = ""

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: Log.subsystem, category: "app")

    /// How often to check the drive for changes made elsewhere.
    private let pollInterval: Duration = .seconds(30)

    func start() {
        guard let store = AppGroup.sessionStore() else {
            message = "App Group container unavailable. Build the app with scripts/build-app.sh."
            return
        }
        if let session = try? store.load() {
            state = .signedIn(handle: session.handle)
            Task { await addToFinder(handle: session.handle) }
        }
        polling = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.syncNow()
            }
        }
    }

    func signIn() async {
        guard let store = AppGroup.sessionStore(), !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let session = try await Auth.login(identifier: handle, password: password, resolver: IdentityResolver())
            try store.save(session)
            password = ""
            state = .signedIn(handle: session.handle)
            await addToFinder(handle: session.handle)
        } catch {
            message = String(describing: error)
        }
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

    func openInFinder() async {
        guard let manager = DriveDomain.manager else { return }
        do {
            NSWorkspace.shared.open(try await manager.getUserVisibleURL(for: .rootContainer))
        } catch {
            message = "Couldn't open the drive: \(error.localizedDescription)"
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
            try await NSFileProviderManager.add(DriveDomain.make(displayName: "@\(handle)"))
        } catch {
            message = "Couldn't add ATDrive to Finder: \(error.localizedDescription)"
            logger.error("adding domain failed: \(String(describing: error), privacy: .public)")
        }
    }
}

import ATDriveCore
import ATDriveMacSupport
import FileProvider
import Foundation

/// The extension's view of the drive: the latest tree, plus the last few trees by revision so
/// enumerators can report "what changed since revision X" by comparing two snapshots.
///
/// The repo revision (a TID that moves on every write) doubles as the File Provider sync anchor.
/// Checking it is one small request, so a full listing only happens when something changed.
actor DriveIndex {
    private var cachedDrive: Drive?
    private var current: (revision: String, tree: DriveTree)?
    private var history: [(revision: String, tree: DriveTree)] = []
    private let historyLimit = 16

    /// Anchor for a drive nothing has been written to yet.
    static let emptyRevision = "empty"

    /// The logged-in account's drive. Read lazily, so logging in after the extension starts works.
    func drive() throws -> Drive {
        if let cachedDrive { return cachedDrive }
        guard let store = AppGroup.sessionStore(), let session = try store.load() else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let manager = SessionManager(session) { updated in try? store.save(updated) }
        let drive = Drive(client: XRPCClient(service: session.service, session: manager), owner: session.did)
        cachedDrive = drive
        return drive
    }

    /// The drive as it is now: re-listed only if its revision moved since last time.
    func refresh() async throws -> (revision: String, tree: DriveTree) {
        let drive = try drive()
        let revision = try await drive.latestRevision() ?? Self.emptyRevision
        if let current, current.revision == revision { return current }
        let tree = try await drive.tree()
        let latest = (revision: revision, tree: tree)
        current = latest
        history.removeAll { $0.revision == revision }
        history.append(latest)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        return latest
    }

    /// The tree as it was at a revision this extension has seen, if still remembered.
    func tree(at revision: String) -> DriveTree? {
        history.last { $0.revision == revision }?.tree
    }
}

extension NSFileProviderSyncAnchor {
    init(revision: String) { self.init(Data(revision.utf8)) }
    var revision: String { String(decoding: rawValue, as: UTF8.self) }
}

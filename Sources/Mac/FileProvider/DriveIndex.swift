import ATDriveCore
import ATDriveMacSupport
import FileProvider
import Foundation

/// The extension's view of the drive: the latest tree, plus the last few trees by revision so
/// enumerators can report "what changed since revision X" by comparing two snapshots.
///
/// The repo revision (a TID that moves on every write) doubles as the File Provider sync anchor.
/// The drive is kept current with its change feed (`Drive.update`): one small request when
/// nothing changed, and only what changed otherwise.
actor DriveIndex {
    private var cachedDrive: Drive?
    /// The drive as last fetched, every record included.
    private var snapshot: DriveSnapshot?
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

    /// The drive as it is now, with the changes since last time applied.
    func refresh() async throws -> (revision: String, tree: DriveTree) {
        let drive = try drive()
        let updated = try await drive.update(snapshot)
        if updated.revision == nil, let current, current.revision != Self.emptyRevision {
            // Gone since we last saw it (say the server was wiped). Showing it as empty would
            // delete everything here, which may be the only copy left.
            throw NSFileProviderError(.serverUnreachable)
        }
        snapshot = updated
        let revision = updated.revision ?? Self.emptyRevision
        if let current, current.revision == revision { return current }
        let latest = (revision: revision, tree: updated.tree)
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

    // MARK: What this Mac has seen

    /// The drive as the system last heard about it: the last tree given to it in full through
    /// the working set, plus what it was told about since by our own replies. A folder deleted
    /// here keeps what changed on the drive after that (`ConflictRules.keptWhenDeleting`).
    /// `nil` until the working set has been listed since the extension started.
    private var seen: [String: Node]?
    /// Items to report as changed the next time the working set is asked for changes, even if
    /// they didn't change: things a delete here didn't remove, so the system puts them back.
    private var resend: Set<String> = []

    func markSeen(_ tree: DriveTree) {
        seen = tree.nodes
    }

    /// Records an item as the system now knows it (from a reply to one of its requests).
    func noteSeen(_ node: Node, parent: String?) {
        guard seen != nil else { return }
        var record = node.record
        record.parent = parent
        seen?[node.id] = Node(id: node.id, cid: node.cid, record: record)
    }

    func seenTree() -> DriveTree? {
        seen.map { DriveTree(Array($0.values)) }
    }

    func seenNode(_ id: String) -> Node? {
        seen?[id]
    }

    func resendNextTime(_ ids: Set<String>) {
        resend.formUnion(ids)
    }

    func takeResend() -> Set<String> {
        defer { resend = [] }
        return resend
    }
}

extension NSFileProviderSyncAnchor {
    init(revision: String) { self.init(rawValue: Data(revision.utf8)) }
    var revision: String { String(decoding: rawValue, as: UTF8.self) }
}

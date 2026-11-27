import ATDriveCore
import ATDriveMacSupport
import FileProvider
import Foundation
import os

/// The extension's view of the drive: the latest tree, plus the last few trees by revision so
/// enumerators can report "what changed since revision X" by comparing two snapshots.
///
/// The repo revisions (TIDs that move on every write), the home drive's and each mounted space's,
/// together make the File Provider sync anchor (`JoinedSnapshot.anchor`).
/// The drive is kept current with its change feed (`Drive.update`): one small request when
/// nothing changed, and only what changed otherwise.
actor DriveIndex {
    private var cachedDrive: JoinedDrive?
    /// The drive as last fetched, every record included: the home drive and each mounted space.
    private var snapshot: JoinedSnapshot?
    private var current: (revision: String, tree: DriveTree)?
    private var history: [(revision: String, tree: DriveTree)] = []
    private let historyLimit = 16

    /// Anchor for a drive nothing has been written to yet.
    static let emptyRevision = "empty"

    private let logger = Logger(subsystem: Log.subsystem, category: "index")
    /// The commit mismatches last logged, so each is logged once.
    private var loggedMismatches: [String: String] = [:]

    /// The logged-in account's drive, opened (with this Mac's keys, if it's encrypted). Read
    /// lazily, so signing in (and getting the keys) after the extension starts works. Until the
    /// app has opened the drive on this Mac, it's "not signed in". The extension never creates
    /// a drive: the app does.
    func drive() async throws -> JoinedDrive {
        if let cachedDrive { return cachedDrive }
        guard let store = AppGroup.sessionStore(), let session = try store.load(),
            let devices = AppGroup.deviceStore(), let identity = try devices.load()
        else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let manager = SessionManager(session, store: store)
        let drive = Drive(
            client: XRPCClient(service: session.service, session: manager), owner: session.did,
            device: identity.name, identity: identity
        ) { updated in try? devices.save(updated) }
        do {
            try await drive.open()
        } catch is DriveAccessError {
            throw NSFileProviderError(.notAuthenticated)
        }
        let joined = JoinedDrive(
            home: drive, access: SpaceAccess(ownClient: drive.client, resolver: IdentityResolver()),
            spaces: SpacesShare.settings)
        Item.account = session.did
        cachedDrive = joined
        return joined
    }

    /// The drive as last fetched (for sharing actions and badges).
    func latest() -> JoinedSnapshot? { snapshot }

    /// The drive as it is now, with the changes since last time applied.
    func refresh() async throws -> (revision: String, tree: DriveTree) {
        let drive = try await drive()
        // Spaces as config.toml now says (the app passes it on), and Spotlight's setting, which
        // changes every item in it: part of the anchor, so a change is enumerated.
        drive.showSpaces(SpacesShare.settings)
        let spotlight = SpacesShare.spotlight
        var updated = try await drive.update(snapshot)
        if let problem = drive.accessProblem,
            problem == .encryptionRemoved || problem == .settingsRolledBack
                || (drive.mode == .encrypted && drive.keyring == nil)
        {
            // Encryption was turned on and this Mac has no keys yet, or the drive's settings
            // can't be believed. Carrying on would write in the wrong form, or show what can't
            // be read as gone. The app sorts it out; then the drive is opened again.
            cachedDrive = nil
            snapshot = nil
            throw NSFileProviderError(.notAuthenticated)
        }
        if updated.revision == nil, let current, current.revision != Self.emptyRevision {
            // Gone since we last saw it (say the server was wiped). Showing it as empty would
            // delete everything here, which may be the only copy left.
            throw NSFileProviderError(.serverUnreachable)
        }
        // Changes that lost a race between devices, settled as `atdrive sync` does. Only when
        // something changed: a race needs a new version. A failure is tried again next change.
        if updated.revision != nil, updated.revision != snapshot?.revision,
            let settled = try? await drive.settleRaces(in: updated), !settled.isEmpty
        {
            updated = try await drive.update(updated)
        }
        logMismatch(updated)
        hold(updated.tree, before: current?.tree)
        snapshot = updated
        Item.spaces = (updated.spaces, spotlight)
        var revision = updated.anchor ?? Self.emptyRevision
        if updated.spaces != nil, spotlight { revision += " indexed" }
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

    /// The drive, or a shared folder, not matching its signed commit, in the log, once each: the
    /// snapshot notes it (`DriveSnapshot.mismatch`) and carries on, as listing again wouldn't
    /// help.
    private func logMismatch(_ snapshot: JoinedSnapshot) {
        var mismatches = snapshot.home.mismatch.map { ["the drive": String(describing: $0)] } ?? [:]
        for (id, mount) in snapshot.mounts {
            if let mismatch = mount.snapshot?.mismatch {
                mismatches["shared folder \(id)"] = String(describing: mismatch)
            }
        }
        for (what, mismatch) in mismatches.sorted(by: { $0.key < $1.key }) where loggedMismatches[what] != mismatch {
            logger.error("\(what, privacy: .public) doesn't match its commit: \(mismatch, privacy: .public)")
        }
        loggedMismatches = mismatches
    }

    // MARK: What can't be read

    /// Items the drive has but this Mac can't read now (`DriveTree.unreadable`), as this Mac last
    /// could read them, by ID. They stay in Finder as they were, where they were, until they can
    /// be read again: never shown as gone, which would delete their local copies, nor left out
    /// of a full listing (after the extension restarts), which does the same. Kept in the App
    /// Group container, without chunk IDs or keys, so a restart doesn't lose them.
    private lazy var held: [String: Node] = HeldItems.load(account: Item.account)

    /// Notes what's become unreadable since `before` (or since this Mac last listed it), and
    /// forgets what's readable again or gone.
    private func hold(_ tree: DriveTree, before: DriveTree?) {
        var updated = held.filter { tree.unreadable[$0.key] != nil }
        for id in tree.unreadable.keys where updated[id] == nil {
            if let before, let node = before.nodes[id] {
                updated[id] = HeldItems.stripped(node, parent: before.parent(of: id))
            } else if let node = seen?[id] {
                updated[id] = HeldItems.stripped(node, parent: node.record.parent)
            }
        }
        guard updated != held else { return }
        let added = updated.keys.filter { held[$0] == nil }.count
        if added > 0 { logger.notice("\(added, privacy: .public) item(s) can't be read now: kept as they were") }
        held = updated
        HeldItems.save(updated, account: Item.account)
    }

    /// An item that can't be read now, as this Mac last saw it (`record.parent` is the folder it
    /// was shown in); `nil` if it never could.
    func heldNode(_ id: String) -> Node? { held[id] }

    /// Every such item.
    func heldNodes() -> [Node] { Array(held.values) }

    // MARK: What this Mac has seen

    /// The drive as the system last heard about it: the last tree given to it in full through
    /// the working set, plus what it was told about since by our own replies. A folder deleted
    /// here keeps what changed on the drive after that (`ConflictRules.keptWhenDeleting`).
    /// `nil` until the working set has been listed since the extension started.
    private var seen: [String: Node]?
    /// Items to report as changed the next time the working set is asked for changes, even if
    /// they didn't change: things a delete here didn't remove, so the system puts them back.
    private var resend: Set<String> = []

    /// What can't be read now stays as it was last seen (`held`).
    func markSeen(_ tree: DriveTree) {
        var nodes = tree.nodes
        for (id, node) in held where tree.unreadable[id] != nil { nodes[id] = node }
        seen = nodes
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

    /// Ignore files' text, by record CID (`isIgnored`).
    private(set) var ignoreTexts: [String: String] = [:]

    func rememberIgnoreText(_ text: String, for cid: String) {
        if ignoreTexts.count > 256 { ignoreTexts = [:] }
        ignoreTexts[cid] = text
    }
}

// MARK: Ignore files

extension DriveIndex {
    /// Whether something new called `name` in `folder` is to stay on this Mac only: ignored by the
    /// ignore files in the drive above it (`.atdriveignore`, `.gitignore`), and config.toml's
    /// `ignore.*` (passed on by the app), as `atdrive sync` would ignore it (`IgnoreRules`).
    /// Something inside a folder that's ignored is ignored too. Throws if an ignore file can't be
    /// read: better to try again later than to upload what it may ignore.
    func isIgnored(_ name: String, isFolder: Bool, in folder: String?, tree: DriveTree) async throws -> Bool {
        let settings = IgnoreShare.settings
        var rules = IgnoreRules(settings)
        for place in IgnoreRules.files(for: folder, in: tree, settings: settings) {
            rules.add(
                folder: place.folder, atdriveignore: try await text(of: place.atdriveignore),
                gitignore: try await text(of: place.gitignore))
        }
        guard !rules.isEmpty else { return false }
        let above = folder.flatMap { tree.nodes[$0] }.map { tree.path(of: $0).components } ?? []
        var lookup = IgnoreRules.Lookup(rules)
        return lookup.isIgnored(above + [name], isFolder: isFolder)
    }

    /// An ignore file's text, remembered by record CID (which changes when it's edited).
    private func text(of node: Node?) async throws -> String? {
        guard let node else { return nil }
        if let known = ignoreTexts[node.cid] { return known }
        guard (node.record.size ?? 0) <= IgnoreRules.maximumFileSize else { return nil }
        var data = Data()
        try await drive().read(node) { data += $0 }
        let text = String(decoding: data, as: UTF8.self)
        rememberIgnoreText(text, for: node.cid)
        return text
    }
}

/// Where `DriveIndex.held` is kept: `held-items.json` in the App Group container, for one account.
enum HeldItems {
    private struct Stored: Codable {
        var account: String
        var items: [String: Item]
        struct Item: Codable {
            var cid: String
            var record: NodeRecord
        }
    }

    private static var file: URL? { AppGroup.containerURL?.appendingPathComponent("held-items.json") }

    static func load(account: String?) -> [String: Node] {
        guard let account, let file, let data = try? Data(contentsOf: file),
            let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.account == account
        else { return [:] }
        return stored.items.reduce(into: [:]) {
            $0[$1.key] = Node(id: $1.key, cid: $1.value.cid, record: $1.value.record)
        }
    }

    static func save(_ nodes: [String: Node], account: String?) {
        guard let account, let file else { return }
        guard !nodes.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let stored = Stored(
            account: account, items: nodes.mapValues { Stored.Item(cid: $0.cid, record: $0.record) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// What Finder needs of a node, in the folder it's shown in, and nothing that opens its
    /// contents: no chunks (whose IDs decrypt them), and no keys of a shared folder.
    static func stripped(_ node: Node, parent: String?) -> Node {
        var record = node.record
        record.parent = parent
        record.chunks = nil
        record.continuations = nil
        record.continuationsFrom = nil
        record.mount?.keyring = nil
        record.mount?.linkKey = nil
        return Node(id: node.id, cid: node.cid, record: record)
    }
}

extension NSFileProviderSyncAnchor {
    init(revision: String) { self.init(rawValue: Data(revision.utf8)) }
    var revision: String { String(decoding: rawValue, as: UTF8.self) }
}

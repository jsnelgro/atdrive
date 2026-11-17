import Foundation

// A drive made of several spaces: the home drive, and the spaces mounted in it (shared folders,
// yours and other people's). Each space is its own `Drive`, with its own mode, keys, history and
// change feed; `JoinedDrive` puts them together as one tree, and sends each change to the space it
// belongs in.
//
// Node IDs are strings everywhere (the tree, sync state, the Mac's item identifiers). A home
// node's ID is its record key; a mounted node's is the mount's ID, a slash, then its record key
// in its space (`NodeID`). Record keys never hold a slash, and mounts don't nest, so that's
// unambiguous, and stays the same as long as the mount does.

/// Why sharing, or something it needs, can't happen.
public enum SharingError: Error, Equatable, CustomStringConvertible {
    /// A mount would store a space's keyring where the PDS can read it (a plain drive).
    case keyringWouldBeReadable
    /// Mounts don't nest: nothing inside a mount can be shared, and a mount can't go in another.
    case nested(String)
    /// It's shared already (it's a mount).
    case alreadyShared(String)
    /// The top of the drive can't be shared, only what's in it.
    case cantShareRoot
    /// A plain drive makes plain shares only.
    case encryptedShareFromPlainDrive
    /// Not one of yours: only its owner can change who has it.
    case notYours(String)
    /// Not shared: no folder of yours there is in a space of its own.
    case notShared(String)
    /// An encrypted share's link has to carry its key (`#…`).
    case linkKeyMissing
    /// The link's key doesn't open the share: wrong, or the link was turned off.
    case linkKeyWrong
    /// The person has no sharing key: they haven't used ATDrive yet.
    case noSharingKey(String)

    public var description: String {
        switch self {
        case .keyringWouldBeReadable:
            "an unencrypted drive can't hold an encrypted share's keys: the PDS could read them"
        case .nested(let path): "\(path) is inside a shared folder: shared folders can't go inside each other"
        case .alreadyShared(let path): "\(path) is already shared"
        case .cantShareRoot: "the top of the drive can't be shared: share a file or folder in it"
        case .encryptedShareFromPlainDrive:
            "your drive isn't encrypted, so it makes unencrypted shares only (`atdrive encryption on` first)"
        case .notYours(let path): "\(path) was shared with you: only its owner can change who has it"
        case .notShared(let path): "\(path) isn't shared"
        case .linkKeyMissing: "this link is to an encrypted share, but it's missing its key (the part after #)"
        case .linkKeyWrong: "this link's key doesn't open the share: it's mistyped, or the link was turned off"
        case .noSharingKey(let who):
            "\(who) hasn't set up ATDrive yet, so there's no key to share encrypted files with; send a link instead"
        }
    }
}

/// Splits and joins node IDs across spaces (see the top of this file).
public enum NodeID {
    public static func join(_ mount: String?, _ rkey: String) -> String { mount.map { "\($0)/\(rkey)" } ?? rkey }

    /// The mount a node is in (`nil`: the home drive), and its record key there.
    public static func split(_ id: String) -> (mount: String?, rkey: String) {
        guard let slash = id.firstIndex(of: "/") else { return (nil, id) }
        return (String(id[..<slash]), String(id[id.index(after: slash)...]))
    }
}

/// Why a mounted space can't be read right now. Its mount is held: what was synced from it stays,
/// untouched, until it can be read again.
public enum MountProblem: Sendable, Equatable, CustomStringConvertible {
    case access(SpaceAccessProblem)
    /// This device can't open it: an encrypted share whose keys it doesn't have.
    case keys(String)
    /// Couldn't reach it (network trouble, say).
    case unreachable(String)

    public var description: String {
        switch self {
        case .access(let problem): problem.description
        case .keys(let why): why
        case .unreachable(let why): "couldn't reach it: \(why)"
        }
    }

    /// Its owner deleted it: unlike anything else, that's not a reason to keep what was synced
    /// from it (0016, "Space deletion").
    public var isDeletion: Bool { self == .access(.deleted) }
}

/// A space mounted in the drive, as last fetched.
public struct MountState: Sendable {
    public var info: MountInfo
    /// `nil` before it's been read.
    public var snapshot: DriveSnapshot?
    /// Why it couldn't be read the last time, if it couldn't.
    public var problem: MountProblem?
    /// Someone else's space: only they can change it.
    public var readOnly: Bool
    /// Its mode, once known.
    public var mode: DriveMode?

    public var space: String { info.space }
    public var owner: String { info.owner }
    /// What was synced from it stays as it is (see `MountProblem`).
    public var isHeld: Bool { problem.map { !$0.isDeletion } ?? false }
}

/// The drive as last fetched, every space in it: the home drive, and each mount.
public struct JoinedSnapshot: Sendable {
    public private(set) var home: DriveSnapshot
    /// By mount ID.
    public private(set) var mounts: [String: MountState]
    /// Every space's files and folders, joined at their mounts, by node ID (`NodeID`).
    public private(set) var tree: DriveTree

    public init(home: DriveSnapshot, mounts: [String: MountState] = [:]) {
        self.home = home
        self.mounts = mounts
        tree = Self.join(home.tree, mounts)
    }

    /// The home drive's revision: `nil` if it's gone.
    public var revision: String? { home.revision }

    /// Where every space is: the home drive's revision, then each mount's (`id=rev`), in order.
    /// It moves whenever any of them does: the Mac's sync anchor. `nil` if the home drive is gone.
    public var anchor: String? {
        guard let revision else { return nil }
        let mounted = mounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.snapshot?.revision ?? "-")" }
        return ([revision] + mounted).joined(separator: " ")
    }
    public var settings: DriveSettings? { home.settings }
    public var listedAt: Date { home.listedAt }

    /// Mounts whose contents are held (see `MountProblem`), by ID.
    public var held: Set<String> { Set(mounts.filter { $0.value.isHeld }.keys) }

    /// Chunks the drive's own spaces already have (their CIDs), for `upload`'s `known`. Blobs are
    /// the account's, so one in any of its spaces needn't be uploaded again.
    public var chunkCIDs: Set<String> {
        mounts.values.filter { !$0.readOnly }.reduce(home.chunkCIDs) { $0.union($1.snapshot?.chunkCIDs ?? []) }
    }

    /// The mount state of the space a node is in (`nil` for the home drive).
    public func mount(of id: String) -> MountState? { NodeID.split(id).mount.flatMap { mounts[$0] } }

    /// The snapshot of the space a path is in, and the path's node there: for history, which is per
    /// space. `nil` for a path in a mount that hasn't been read.
    public func locate(_ path: DrivePath) throws -> (mount: String?, snapshot: DriveSnapshot, node: Node?)? {
        let node = try tree.locate(path)
        guard let node else { return (nil, home, nil) }
        let (mount, rkey) = NodeID.split(node.id)
        guard let mount else { return (nil, home, home.tree.nodes[rkey]) }
        guard let snapshot = mounts[mount]?.snapshot else { return nil }
        return (mount, snapshot, snapshot.tree.nodes[rkey])
    }

    /// The drive as it was at `date`, every space at that moment, joined at today's mounts.
    public func tree(at date: Date) -> DriveTree {
        let homePast = home.tree(at: date)
        var past = mounts
        for (id, state) in mounts {
            if let snapshot = state.snapshot { past[id]?.snapshot = snapshot.replacingTree(snapshot.tree(at: date)) }
        }
        return Self.join(homePast, past)
    }

    /// The home tree with each readable mount's tree inside its mount node.
    static func join(_ home: DriveTree, _ mounts: [String: MountState]) -> DriveTree {
        var nodes = Array(home.nodes.values)
        var unreadable = Array(home.unreadable.values)
        for (id, state) in mounts.sorted(by: { $0.key < $1.key }) where home.nodes[id] != nil && state.problem == nil {
            guard let tree = state.snapshot?.tree else { continue }
            for node in tree.nodes.values {
                var record = node.record
                record.parent = tree.parent(of: node.id).map { NodeID.join(id, $0) } ?? id
                nodes.append(Node(id: NodeID.join(id, node.id), cid: node.cid, record: record))
            }
            unreadable += tree.unreadable.values.map {
                UnreadableNode(id: NodeID.join(id, $0.id), cid: $0.cid, reason: $0.reason, value: $0.value)
            }
        }
        return DriveTree(nodes, unreadable: unreadable)
    }
}

extension DriveSnapshot {
    /// The same, with another tree: for a point in the past.
    func replacingTree(_ tree: DriveTree) -> DriveSnapshot {
        var copy = self
        copy.setTree(tree)
        return copy
    }
}

/// The home drive and the spaces mounted in it, as one drive. Reading joins their trees
/// (`JoinedSnapshot`); writing goes to the space a node is in. Other people's spaces are read
/// with a credential (`SpaceAccess`) and are read-only.
public final class JoinedDrive: Sendable {
    public let home: Drive
    /// How other accounts' spaces are read; `nil`: they can't be (they're held).
    public let access: SpaceAccess?
    let opened = Locked<[String: Opened]>([:])
    /// The last snapshot `update` made: where writes find the nodes they move or delete.
    private let latest = Locked<JoinedSnapshot?>(nil)

    struct Opened: Sendable {
        var info: MountInfo
        var drive: Drive
        var readOnly: Bool
    }

    public init(home: Drive, access: SpaceAccess?) {
        self.home = home
        self.access = access
    }

    public var owner: String { home.owner }
    public var space: String { home.space }
    public var client: XRPCClient { home.client }
    public var mode: DriveMode? { home.mode }
    public var keyring: Keyring? { home.keyring }
    public var identity: DeviceIdentity? { home.identity }
    public var accessProblem: DriveAccessError? { home.accessProblem }

    // MARK: Reading

    /// Brings every space up to date: the home drive, then each mount in it. A mount that can't
    /// be read keeps what it had, and says why (`MountState.problem`).
    public func update(_ snapshot: JoinedSnapshot?, now: Date = Date()) async throws -> JoinedSnapshot {
        let home = try await self.home.update(snapshot?.home, now: now)
        var mounts: [String: MountState] = [:]
        let mountNodes = home.tree.nodes.values.filter(\.isMount).sorted { $0.id < $1.id }
        let sharingKeys = home.settings?.sharingKeyPair(encrypted: self.home.mode == .encrypted)
        for node in mountNodes {
            guard let info = node.record.mount else { continue }
            let previous = snapshot?.mounts[node.id].flatMap { $0.space == info.space ? $0 : nil }
            mounts[node.id] = await updateMount(
                node.id, info: info, previous: previous, sharingKeys: sharingKeys, now: now)
        }
        opened.update { $0 = $0.filter { mounts[$0.key] != nil } }
        let joined = JoinedSnapshot(home: home, mounts: mounts)
        latest.update { $0 = joined }
        return joined
    }

    /// The whole drive, every space, fetched from scratch.
    public func tree() async throws -> DriveTree { try await update(nil).tree }

    private func updateMount(
        _ id: String, info: MountInfo, previous: MountState?, sharingKeys: SharingKeyPair?, now: Date
    ) async -> MountState {
        let readOnly = info.owner != owner
        var state = previous ?? MountState(info: info, readOnly: readOnly)
        state.info = info
        state.readOnly = readOnly
        do {
            var drive = try await open(id, info, sharingKeys: sharingKeys)
            var snapshot = try await drive.update(state.snapshot, now: now)
            if readOnly, drive.mode == .encrypted,
                snapshot.tree.unreadable.values.contains(where: { $0.reason == .missingKey })
            {
                // Sealed with a key this device doesn't have yet: its owner added one (after
                // removing someone, say). The keyring is fetched again.
                opened.update { $0[id] = nil }
                drive = try await open(id, info, sharingKeys: sharingKeys)
                snapshot = try await drive.update(nil, now: now)
            }
            state.mode = drive.mode
            guard snapshot.revision != nil else {
                // No repo: the space is gone, or (with a credential) it says nothing. Never empty.
                state.problem = .access(.notShared)
                opened.update { $0[id] = nil }
                return state
            }
            state.snapshot = snapshot
            state.problem = nil
        } catch {
            opened.update { $0[id] = nil }
            if let access = SpaceAccessProblem(error) {
                state.problem = .access(access)
                if access == .deleted { state.snapshot = nil }
            } else if let keys = error as? DriveAccessError {
                state.problem = .keys(keys.description)
            } else if let sharing = error as? SharingError {
                state.problem = .keys(sharing.description)
            } else {
                state.problem = .unreachable("\(error)")
            }
        }
        return state
    }

    /// The `Drive` for a mounted space, opened: its mode from its settings, and an encrypted one's
    /// keys from the mount (yours), or else from its link or member record (`keyring(for:)`).
    func open(_ id: String, _ info: MountInfo, sharingKeys: SharingKeyPair?) async throws -> Drive {
        if let opened = opened.value[id], opened.info == info { return opened.drive }
        let readOnly = info.owner != owner
        let client: XRPCClient
        if readOnly {
            guard let access else { throw MountUnavailable() }
            client = try await access.credentials(for: info.space).client
        } else {
            client = home.client
        }
        let probe = Drive(client: client, owner: info.owner, space: info.space)
        guard let settings = try await probe.settingsRecord() else {
            throw XRPCError(method: "com.atproto.space.listRecords", status: 400, body: Data(#"{"error":"SpaceNotFound"}"#.utf8))
        }
        let encrypted = settings.value.flatMap(SealedRecord.init) != nil
        var keyring: Keyring?
        if encrypted {
            if let own = info.spaceKeyring {
                keyring = own
            } else {
                keyring = try await self.keyring(for: info, client: client, sharingKeys: sharingKeys)
            }
        }
        let drive = Drive(
            client: client, owner: info.owner, space: info.space, transfers: home.transfers, device: home.device,
            tids: home.tids, identity: home.identity, mode: encrypted ? .encrypted : .plain, keyring: keyring)
        opened.update { $0[id] = Opened(info: info, drive: drive, readOnly: readOnly) }
        return drive
    }

    /// An encrypted share's keyring, for a mount that doesn't hold it: from its link record, with
    /// the link key in the mount. (Member records are read in `Sharing.swift`.)
    func keyring(for info: MountInfo, client: XRPCClient, sharingKeys: SharingKeyPair?) async throws -> Keyring {
        if let linkKey = info.linkKey {
            return try await ShareLink.keyring(space: info.space, owner: info.owner, linkKey: linkKey.data, client: client)
        }
        guard let sharingKeys else { throw SharingError.linkKeyMissing }
        return try await MemberKeys.keyring(
            space: info.space, owner: info.owner, me: owner, keys: sharingKeys, client: client, resolver: access?.resolver)
    }

    struct MountUnavailable: Error, CustomStringConvertible {
        var description: String { "other people's shares can't be read here" }
    }

    // MARK: Writing

    /// Where a new child of `parent` goes: its space's drive and its parent there.
    private func place(_ parent: String?, path: @autoclosure () -> String) throws -> (Drive, String?, mount: String?) {
        guard let parent else { return (home, nil, nil) }
        let (mount, rkey) = NodeID.split(parent)
        if let mount { return (try writable(mount, path: path()), rkey, mount) }
        if let opened = opened.value[parent] {
            guard !opened.readOnly else { throw ATDriveError.readOnly(path: path(), owner: opened.info.owner) }
            return (opened.drive, nil, parent)
        }
        if let state = latest.value?.mounts[parent] {
            if state.readOnly { throw ATDriveError.readOnly(path: path(), owner: state.owner) }
            throw ATDriveError.mountUnavailable(path: path(), why: state.problem?.description ?? "it can't be read")
        }
        return (home, parent, nil)
    }

    private func writable(_ mount: String, path: String) throws -> Drive {
        if let opened = opened.value[mount] {
            guard !opened.readOnly else { throw ATDriveError.readOnly(path: path, owner: opened.info.owner) }
            return opened.drive
        }
        let state = latest.value?.mounts[mount]
        if let state, state.readOnly { throw ATDriveError.readOnly(path: path, owner: state.owner) }
        throw ATDriveError.mountUnavailable(path: path, why: state?.problem?.description ?? "it can't be read")
    }

    /// The drive a node is in, and the node as that drive knows it.
    private func local(_ node: Node, writing: Bool) throws -> (Drive, Node, mount: String?) {
        let (mount, rkey) = NodeID.split(node.id)
        guard let mount else { return (home, node, nil) }
        let drive: Drive
        if writing {
            drive = try writable(mount, path: node.name)
        } else {
            guard let opened = opened.value[mount] else {
                throw ATDriveError.mountUnavailable(
                    path: node.name, why: latest.value?.mounts[mount]?.problem?.description ?? "it can't be read")
            }
            drive = opened.drive
        }
        var record = node.record
        if record.parent == mount {
            record.parent = nil
        } else if let parent = record.parent {
            record.parent = NodeID.split(parent).rkey
        }
        return (drive, Node(id: rkey, cid: node.cid, record: record), mount)
    }

    private func global(_ node: Node, in mount: String?) -> Node {
        guard let mount else { return node }
        var record = node.record
        record.parent = record.parent.map { NodeID.join(mount, $0) } ?? mount
        return Node(id: NodeID.join(mount, node.id), cid: node.cid, record: record)
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String?) async throws -> Node {
        let (drive, local, mount) = try place(parent, path: name)
        return global(try await drive.createFolder(named: name, in: local), in: mount)
    }

    /// Uploads a file into `parent`'s space (see `Drive.upload`). Replacing a file in another
    /// space (it moved there too) uploads it there, and deletes the old one.
    @discardableResult
    public func upload(
        _ file: URL, as name: String, in parent: String?, replacing existing: Node? = nil, modified: Date? = nil,
        known: Set<String> = [], progress: Drive.Progress? = nil
    ) async throws -> Node {
        let (drive, localParent, mount) = try place(parent, path: name)
        var replacing: Node?
        var stale: Node?
        if let existing {
            let (existingDrive, node, _) = try local(existing, writing: true)
            if existingDrive === drive { replacing = node } else { stale = existing }
        }
        let written = try await drive.upload(
            file, as: name, in: localParent, replacing: replacing, modified: modified, known: known, progress: progress)
        if let stale { try await delete([stale]) }
        return global(written, in: mount)
    }

    /// Renames and/or moves a node. Within a space it's a move; between two (into or out of a
    /// shared folder of yours) it's a copy, then a delete, and it gets a new ID.
    @discardableResult
    public func move(_ node: Node, to parent: String?, as name: String) async throws -> Node {
        let (source, local, sourceMount) = try self.local(node, writing: true)
        let (target, localParent, targetMount) = try place(parent, path: name)
        if source === target { return global(try await source.move(local, to: localParent, as: name), in: targetMount) }
        guard !node.isMount else { throw SharingError.nested(name) }
        let tree = latest.value?.tree ?? DriveTree([])
        guard !tree.descendants(of: node.id).contains(where: \.isMount) else { throw SharingError.nested(name) }
        let copied = try await copy(node, in: tree, from: source, to: target, parent: localParent, as: name)
        let inside = node.isFolder ? tree.descendants(of: node.id) : []
        let doomed = try (inside + [node]).map { try self.local($0, writing: true).1 }
        try await source.delete(doomed)
        _ = sourceMount
        return global(copied, in: targetMount)
    }

    /// Copies a node (with everything in it) into another of the account's spaces, as new nodes.
    /// Chunks are reused between spaces of the same mode; between an encrypted and a plain one,
    /// files are downloaded and uploaded again in the target's form.
    func copy(
        _ node: Node, in tree: DriveTree, from source: Drive, to target: Drive, parent: String?, as name: String,
        keepingIDs: Bool = false
    ) async throws -> Node {
        let local = try self.local(node, writing: false).1
        let id = keepingIDs ? local.id : nil
        let written: Node
        if node.isFolder {
            written = try await target.writeCopy(of: local.record, id: id, in: parent, as: name)
            for child in tree.children(of: node.id) {
                _ = try await copy(child, in: tree, from: source, to: target, parent: written.id, as: child.name, keepingIDs: keepingIDs)
            }
        } else if source.mode == target.mode {
            written = try await target.writeCopy(of: local.record, id: id, in: parent, as: name)
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("atdrive-copy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            try await source.download(local, to: scratch)
            let uploaded = try await target.upload(
                scratch, as: name, in: parent, modified: local.record.modifiedDate)
            written = uploaded
        }
        return written
    }

    @discardableResult
    public func restore(_ node: Node) async throws -> Node {
        let (drive, local, mount) = try self.local(node, writing: true)
        return global(try await drive.restore(local), in: mount)
    }

    /// Deletes nodes, each in its space. A mount's deletion removes the mount only: the space and
    /// what's in it stay (so anything inside a mount deleted with it is left alone).
    public func delete(_ nodes: [Node]) async throws {
        let mounts = Set(nodes.filter(\.isMount).map(\.id))
        var bySpace: [String?: (Drive, [Node])] = [:]
        for node in nodes {
            if let mount = NodeID.split(node.id).mount, mounts.contains(mount) { continue }
            let (drive, local, mount) = try self.local(node, writing: true)
            bySpace[mount, default: (drive, [])].1.append(local)
        }
        for (_, (drive, nodes)) in bySpace.sorted(by: { ($0.key ?? "") < ($1.key ?? "") }) {
            try await drive.delete(nodes)
        }
    }

    public func read(_ node: Node, previous: URL? = nil, progress: Drive.Progress? = nil, into write: (Data) throws -> Void)
        async throws
    {
        let (drive, local, _) = try self.local(node, writing: false)
        try await drive.read(local, previous: previous, progress: progress, into: write)
    }

    public func download(_ node: Node, to destination: URL, previous: URL? = nil, progress: Drive.Progress? = nil)
        async throws
    {
        let (drive, local, _) = try self.local(node, writing: false)
        try await drive.download(local, to: destination, previous: previous, progress: progress)
    }

    public func isUnchanged(_ file: URL, comparedTo node: Node) throws -> Bool {
        try home.isUnchanged(file, comparedTo: node)
    }

    // MARK: History, per space

    /// Settles races in every space this account writes (see `Drive.settleRaces`).
    public func settleRaces(in snapshot: JoinedSnapshot, now: Date = Date()) async throws -> [Drive.SettledRace] {
        var settled = try await home.settleRaces(in: snapshot.home, now: now)
        for (id, state) in snapshot.mounts.sorted(by: { $0.key < $1.key }) where !state.readOnly && state.problem == nil {
            guard let mounted = state.snapshot, let drive = opened.value[id]?.drive else { continue }
            settled += try await drive.settleRaces(in: mounted, now: now).map { race in
                var race = race
                race.node = NodeID.join(id, race.node)
                race.written = global(race.written, in: id)
                return race
            }
        }
        return settled
    }

    /// Prunes the history of every space this account writes (see `Drive.prune`).
    public func prune(_ snapshot: JoinedSnapshot, now: Date = Date()) async throws -> Int {
        var pruned = try await home.prune(snapshot.home, now: now)
        for (id, state) in snapshot.mounts.sorted(by: { $0.key < $1.key }) where !state.readOnly && state.problem == nil {
            guard let mounted = state.snapshot, let drive = opened.value[id]?.drive else { continue }
            pruned += try await drive.prune(mounted, now: now)
        }
        return pruned
    }

    /// Mounts `info`'s space in the home drive, as `name` in `parent` (a home folder: mounts
    /// don't nest). Returns the mount node.
    @discardableResult
    public func mount(_ info: MountInfo, named name: String, in parent: String?) async throws -> Node {
        if let parent, NodeID.split(parent).mount != nil || opened.value[parent] != nil
            || latest.value?.mounts[parent] != nil
        {
            throw SharingError.nested(name)
        }
        return try await home.createMount(info, named: name, in: parent)
    }

    /// The drive of a mount, opened (for history and sharing commands).
    public func drive(ofMount id: String) -> Drive? { opened.value[id]?.drive }

    /// The drive a node is in, and its record key there.
    public func space(of id: String) -> (drive: Drive, rkey: String)? {
        let (mount, rkey) = NodeID.split(id)
        guard let mount else { return (home, rkey) }
        return opened.value[mount].map { ($0.drive, rkey) }
    }
}

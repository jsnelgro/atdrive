import Crypto
import Foundation

/// A drive: one atproto space holding one record per file or folder, with file contents
/// stored as chunked blobs. Everything here works by node ID; `DriveTree` maps paths to IDs.
public final class Drive: Sendable {
    public let client: XRPCClient
    /// DID of the account that owns the drive (and, for now, the only one writing to it).
    public let owner: String
    /// The space's URI.
    public let space: String
    /// Files are split into blobs of this size.
    public let chunkSize: Int
    /// Recorded on every change this makes (`VersionRecord.device`).
    public let device: String
    /// Where new IDs (and so the times of changes) come from.
    public let tids: TIDSource
    /// Whether a write to a drive that doesn't exist creates it. Only for a drive that's new:
    /// one this device has synced before and is now gone was wiped (say the server was reset),
    /// and creating it again would leave only what's written next.
    public let createsDrive: Bool

    public typealias Progress = @Sendable (_ bytesDone: Int, _ bytesTotal: Int) -> Void

    public convenience init(
        client: XRPCClient, owner: String, key: String = Lexicon.defaultDriveKey,
        chunkSize: Int = 4 * 1024 * 1024, device: String = DeviceName.current, tids: TIDSource = .system,
        createsDrive: Bool = false
    ) {
        self.init(
            client: client, owner: owner,
            space: XRPCClient.spaceURI(authority: owner, type: Lexicon.driveSpace, key: key), chunkSize: chunkSize,
            device: device, tids: tids, createsDrive: createsDrive)
    }

    private init(
        client: XRPCClient, owner: String, space: String, chunkSize: Int, device: String, tids: TIDSource,
        createsDrive: Bool
    ) {
        self.client = client
        self.owner = owner
        self.space = space
        self.chunkSize = chunkSize
        self.device = device
        self.tids = tids
        self.createsDrive = createsDrive
    }

    /// Opens the logged-in account's drive.
    public convenience init(
        session: SessionManager, transport: any HTTPTransport = URLSessionTransport(), createsDrive: Bool = false
    ) async {
        let current = await session.session
        self.init(
            client: XRPCClient(service: current.service, session: session, transport: transport),
            owner: current.did, createsDrive: createsDrive)
    }

    /// The same drive, creating it on a write or not (`createsDrive`).
    public func with(createsDrive: Bool) -> Drive {
        Drive(
            client: client, owner: owner, space: space, chunkSize: chunkSize, device: device, tids: tids,
            createsDrive: createsDrive)
    }

    // MARK: Reading

    /// Every file and folder in the drive. An empty drive (or one never written to) is empty.
    /// Records this device can't read are in the tree's `unreadable`.
    public func tree() async throws -> DriveTree {
        var entries: [NodeEntry] = []
        var cursor: String?
        repeat {
            let page: XRPCClient.SpaceRecordPage<JSONValue>
            do {
                page = try await client.listRawSpaceRecords(
                    space: space, repo: owner, collection: Lexicon.node, cursor: cursor)
            } catch let error as XRPCError where Self.isMissing(error) {
                return DriveTree([])
            }
            entries += page.records.map { readNode(id: $0.rkey, cid: $0.cid, value: $0.value) }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return DriveTree(entries)
    }

    /// The one place a stored node record becomes a `Node`, for listings and the change feed
    /// alike. A record that doesn't decode (a newer format) is unreadable rather than dropped,
    /// so it can't look deleted; so is one whose name could escape a local folder (e.g. `..`)
    /// when downloaded. Our own writes never produce either.
    public func readNode(id: String, cid: String, value: JSONValue?) -> NodeEntry {
        guard let value, let record = try? value.decode(as: NodeRecord.self) else {
            return .unreadable(UnreadableNode(id: id, cid: cid, reason: .newerFormat, value: value))
        }
        guard (try? DrivePath.validate(name: record.name)) != nil else {
            return .unreadable(UnreadableNode(id: id, cid: cid, reason: .invalidName, value: value))
        }
        return .readable(Node(id: id, cid: cid, record: record))
    }

    // MARK: Following changes

    /// Every write since `revision`, in every collection, in order (pages followed to the end),
    /// and the commit the drive is now at: `nil` if the drive has no repo (gone, or never
    /// written to). The feed may have been compacted: `DriveSnapshot` checks that it connects.
    public func changes(since revision: String) async throws -> DriveChanges {
        var ops: [RepoOp] = []
        var cursor: String?
        while true {
            let page: RepoOpsPage
            do {
                page = try await client.listRepoOps(space: space, repo: owner, since: revision, cursor: cursor)
            } catch let error as XRPCError where Self.isMissing(error) {
                return DriveChanges(ops: [], commit: nil)
            }
            ops += page.ops
            guard page.commit == nil, let next = page.cursor, !page.ops.isEmpty else {
                return DriveChanges(ops: ops, commit: page.commit)
            }
            cursor = next
        }
    }

    /// Brings a snapshot of the drive up to date: applies the changes since its revision, which
    /// is one request when nothing changed. Lists the whole drive instead when there's no
    /// snapshot (or revision), when the change feed doesn't connect to it or the server refuses
    /// it, and when the records stop matching the commit (a compacted feed can hide writes).
    /// While a listing itself doesn't match (say the server hashes differently), it also lists
    /// once per process and every hour (see `DriveSnapshot.needsFullListing`).
    ///
    /// A drive that's gone comes back as a snapshot with no revision: callers that have synced
    /// before must not take that for an empty drive.
    public func update(_ snapshot: DriveSnapshot?, now: Date = Date()) async throws -> DriveSnapshot {
        guard var snapshot, let revision = snapshot.revision, !snapshot.needsFullListing(at: now) else {
            return try await listEverything(now: now)
        }
        do {
            try snapshot.apply(try await changes(since: revision), strict: true, read: readNode)
            return snapshot
        } catch let error where error is ChangeFeedGap || Self.isRefusal(error) {
            return try await listEverything(now: now)
        }
    }

    /// The whole drive, every collection, listed from scratch. Writes made while listing are
    /// caught up on with the change feed, so the snapshot is exactly at a revision. It's kept
    /// even if it doesn't match the commit, as `mismatch`: listing again wouldn't help.
    public func listEverything(now: Date = Date()) async throws -> DriveSnapshot {
        var problem = ChangeFeedGap(description: "the drive kept changing while it was listed")
        for _ in 0..<3 {
            guard let commit = try await client.latestSpaceCommit(space: space, repo: owner) else {
                return DriveSnapshot(listedAt: now)
            }
            var listing: [(collection: String, rkey: String, cid: String, value: JSONValue?)] = []
            var cursor: String?
            repeat {
                let page: XRPCClient.SpaceRecordPage<JSONValue>
                do {
                    page = try await client.listRawSpaceRecords(
                        space: space, repo: owner, collection: nil, cursor: cursor)
                } catch let error as XRPCError where Self.isMissing(error) {
                    return DriveSnapshot(listedAt: now)
                }
                listing += page.records.map { ($0.collection ?? Lexicon.node, $0.rkey, $0.cid, $0.value) }
                cursor = page.records.isEmpty ? nil : page.cursor
            } while cursor != nil
            var snapshot = DriveSnapshot(listing: listing, commit: commit, listedAt: now, read: readNode)
            do {
                try snapshot.apply(try await changes(since: commit.rev), strict: false, read: readNode)
                return snapshot
            } catch let gap as ChangeFeedGap {
                problem = gap
            }
        }
        throw problem
    }

    private static func isMissing(_ error: XRPCError) -> Bool {
        error.error == "SpaceNotFound" || error.error == "RepoNotFound"
    }

    /// The server answered, but not with changes we could use (e.g. a revision it no longer
    /// knows). Network trouble isn't one of these: a full listing would fail the same way.
    private static func isRefusal(_ error: Error) -> Bool {
        if error is XRPCError { return true }
        if case .unexpectedResponse? = error as? ATDriveError { return true }
        return false
    }

    /// Streams a file's contents in order, verifying every chunk and the whole file.
    public func read(_ node: Node, progress: Progress? = nil, into write: (Data) throws -> Void)
        async throws
    {
        guard !node.isFolder else { throw ATDriveError.isAFolder(node.name) }
        let total = node.record.size ?? 0
        var hasher = SHA256()
        var done = 0
        for chunk in node.record.chunks ?? [] {
            let data = try await client.getSpaceBlob(space: space, repo: owner, cid: chunk.cid)
            guard CID.forBlob(data) == chunk.cid else {
                throw ATDriveError.integrity("chunk \(chunk.cid) of \(node.name) doesn't match its CID")
            }
            hasher.update(data: data)
            try write(data)
            done += data.count
            progress?(done, total)
        }
        guard done == total else {
            throw ATDriveError.integrity("\(node.name) is \(done) bytes, expected \(total)")
        }
        if let expected = node.record.sha256, hasher.finalize().hexString != expected {
            throw ATDriveError.integrity("\(node.name) doesn't match its SHA-256")
        }
    }

    /// Downloads a file to `destination`, replacing it atomically, and restores its
    /// modification time. A failed download leaves nothing behind.
    public func download(_ node: Node, to destination: URL, progress: Progress? = nil) async throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).atdrive-partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: partial) } }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try await read(node, progress: progress) { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if let modified = node.record.modifiedDate {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: partial.path)
        }
        try replace(destination, with: partial)
        finished = true
    }

    /// The revision (TID) of the latest change to the drive, or `nil` if nothing has ever been
    /// written. To follow changes, use `update` (or `changes(since:)`) instead.
    public func latestRevision() async throws -> String? {
        try await client.latestSpaceRevision(space: space, repo: owner)
    }

    // MARK: Writing

    /// Creates the drive: its space, and its settings with a new drive ID. Returns the drive's
    /// settings: the ones written here, or the ones already there (another device created it).
    /// Writes do this by themselves only if `createsDrive`.
    @discardableResult
    public func create() async throws -> DriveSettings {
        do {
            _ = try await client.createPersonalSpace(type: Lexicon.driveSpace, key: spaceKey)
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {}
        let settings = DriveSettings()
        do {
            try await client.createSpaceRecord(
                space: space, repo: owner, collection: Lexicon.settings, rkey: Lexicon.settingsKey, record: settings)
            return settings
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
            guard let existing = try await self.settings() else {
                throw ATDriveError.unexpectedResponse("the drive's settings exist, but can't be read")
            }
            return existing
        }
    }

    /// The drive's settings, or `nil` if it has none (it doesn't exist, or a version of ATDrive
    /// from before there were settings created it).
    public func settings() async throws -> DriveSettings? {
        let page: XRPCClient.SpaceRecordPage<JSONValue>
        do {
            page = try await client.listRawSpaceRecords(space: space, repo: owner, collection: Lexicon.settings)
        } catch let error as XRPCError where Self.isMissing(error) {
            return nil
        }
        return page.records.first { $0.rkey == Lexicon.settingsKey }?.value.flatMap {
            try? $0.decode(as: DriveSettings.self)
        }
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String?) async throws -> Node {
        try DrivePath.validate(name: name)
        let folder = NodeRecord(name: name, parent: parent, kind: .folder)
        return try await commit(change(.create, node: tids.next(), record: folder, .created, prev: nil))!
    }

    /// Uploads a local file as `name` inside `parent`. Pass `replacing` to overwrite an existing
    /// file in place (it keeps its ID, so other devices see an edit rather than a new file).
    /// The recorded modification time is `modified`, or else the local file's.
    @discardableResult
    public func upload(
        _ file: URL, as name: String, in parent: String?, replacing existing: Node? = nil,
        modified: Date? = nil, progress: Progress? = nil
    ) async throws -> Node {
        try DrivePath.validate(name: name)
        if let existing, existing.isFolder { throw ATDriveError.isAFolder(existing.name) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let total = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        var chunks: [BlobRef] = []
        var done = 0
        progress?(0, total)
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
            let blob = try await client.uploadBlob(data, mimeType: "application/octet-stream")
            guard blob.cid == CID.forBlob(data), blob.size == data.count else {
                throw ATDriveError.integrity("server stored a chunk of \(name) as \(blob.cid)")
            }
            chunks.append(blob)
            done += data.count
            progress?(done, total)
        }

        var record = NodeRecord(
            name: name, parent: parent, kind: .file, size: done,
            sha256: hasher.finalize().hexString, chunks: chunks,
            modifiedAt: modified ?? attributes[.modificationDate] as? Date)
        guard let existing else {
            return try await commit(
                change(.create, node: tids.next(), record: record, .created, prev: nil, newContents: true))!
        }
        record.createdAt = existing.record.createdAt
        var edit = change(
            .update, node: existing.id, record: record, .edited, prev: existing.record.version, newContents: true)
        do {
            return try await commit(edit)!
        } catch let error as XRPCError where error.error == "RecordNotFound" {
            // Deleted elsewhere meanwhile: an edit outlives a delete (`ConflictRules`), so it's
            // written back under its own ID. The delete's version lost the race.
            edit.write = .create
            return try await commit(edit)!
        }
    }

    /// Whether a local file has the same contents as a file in the drive.
    public func isUnchanged(_ file: URL, comparedTo node: Node) throws -> Bool {
        guard !node.isFolder, let size = node.record.size, let sha256 = node.record.sha256,
            (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue == size
        else { return false }
        return try Self.sha256(of: file) == sha256
    }

    /// A local file's hex SHA-256, as recorded in `NodeRecord.sha256`.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().hexString
    }

    /// Renames and/or moves a file or folder. Folders move with everything inside them. Throws
    /// `notFound` if it was deleted meanwhile: a move doesn't keep something deleted elsewhere
    /// (`ConflictRules`).
    @discardableResult
    public func move(_ node: Node, to parent: String?, as name: String) async throws -> Node {
        try DrivePath.validate(name: name)
        var record = node.record
        record.parent = parent
        record.name = name
        do {
            return try await commit(change(.update, node: node.id, record: record, .moved, prev: node.record.version))!
        } catch let error as XRPCError where error.error == "RecordNotFound" {
            throw ATDriveError.notFound(node.name)
        }
    }

    /// Writes a node back under its own ID, e.g. a folder deleted elsewhere that something is
    /// being added to here (see `ConflictRules`). Its contents, if a file, must still exist.
    @discardableResult
    public func restore(_ node: Node) async throws -> Node {
        try DrivePath.validate(name: node.name)
        var restore = change(.create, node: node.id, record: node.record, .restored, prev: node.record.version)
        do {
            return try await commit(restore)!
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
            restore.write = .update
            return try await commit(restore)!
        }
    }

    /// Deletes files and folders, recording each in history (so they're in the trash). To delete
    /// a folder's contents too, include them (see `DriveTree.descendants`), deepest first, so an
    /// interrupted delete leaves no orphans. Anything already deleted elsewhere is skipped.
    public func delete(_ nodes: [Node]) async throws {
        // All the versions first: one delete happens at one moment (see `DriveHistory.sameDeletion`).
        let changes = nodes.map { change(.delete, node: $0.id, record: nil, .deleted, prev: $0.record.version) }
        _ = try await commit(changes)
    }

    private var spaceKey: String { String(space.split(separator: "/").last!) }

    // MARK: Writing with history

    /// A change to one node as it's written: the node record (or its deletion), and the version
    /// that records the change, in the same transaction.
    struct NodeChange: Sendable {
        enum Write: Sendable { case create, update, delete }

        var write: Write
        var node: String
        /// The node as written, its `version` (and `contentsFrom`) filled in; `nil` for a delete.
        var record: NodeRecord?
        var versionID: String
        var version: VersionRecord

        func writes() throws -> [SpaceWrite] {
            let nodeWrite: SpaceWrite
            switch (write, record) {
            case (.create, let record?):
                nodeWrite = .create(collection: Lexicon.node, rkey: node, value: try JSONValue(encoding: record))
            case (.update, let record?):
                nodeWrite = .update(collection: Lexicon.node, rkey: node, value: try JSONValue(encoding: record))
            default:
                nodeWrite = .delete(collection: Lexicon.node, rkey: node)
            }
            return [
                nodeWrite,
                .create(collection: Lexicon.version, rkey: versionID, value: try JSONValue(encoding: version)),
            ]
        }
    }

    /// Stamps a change to `node` with a new version: it becomes `record` (`nil`: deleted), based
    /// on `prev`. A file's version holds the chunk list if `newContents`; otherwise it points to
    /// the version that does (`record.contentsFrom`), so a rename or move copies no chunks.
    func change(
        _ write: NodeChange.Write, node: String, record: NodeRecord?, _ kind: VersionRecord.Change, prev: String?,
        newContents: Bool = false
    ) -> NodeChange {
        let versionID = tids.next()
        var stamped = record
        stamped?.version = versionID
        if let state = stamped {
            if state.kind != .file {
                stamped?.contentsFrom = nil
            } else if newContents || state.contentsFrom == nil {
                stamped?.contentsFrom = versionID
            }
        }
        let version = VersionRecord(
            node: node, change: kind, device: device, prev: prev, state: stamped,
            holdsContents: stamped?.contentsFrom == versionID)
        return NodeChange(write: write, node: node, record: stamped, versionID: versionID, version: version)
    }

    /// Writes one change. Returns the node as written (`nil` for a delete).
    @discardableResult
    func commit(_ change: NodeChange) async throws -> Node? {
        let cids = try await apply(change.writes())
        return change.record.map { Node(id: change.node, cid: cids[0] ?? "", record: $0) }
    }

    /// Writes changes in order, 100 to a transaction (each is two writes). A transaction that
    /// fails because a record already exists, or doesn't exist, is tried again one change at a
    /// time; the changes that fail that way on their own are left out (another device got
    /// there first) and returned as `skipped`.
    func commit(_ changes: [NodeChange]) async throws -> (written: [Node], skipped: [NodeChange]) {
        var written: [Node] = []
        var skipped: [NodeChange] = []
        let perTransaction = XRPCClient.maxWrites / 2
        for start in stride(from: 0, to: changes.count, by: perTransaction) {
            let batch = Array(changes[start..<min(start + perTransaction, changes.count)])
            do {
                let cids = try await apply(try batch.flatMap { try $0.writes() })
                for (index, change) in batch.enumerated() {
                    if let record = change.record {
                        written.append(Node(id: change.node, cid: cids[index * 2] ?? "", record: record))
                    }
                }
            } catch let error as XRPCError where Self.isRace(error) {
                for change in batch {
                    do {
                        if let node = try await commit(change) { written.append(node) }
                    } catch let error as XRPCError where Self.isRace(error) {
                        skipped.append(change)
                    }
                }
            }
        }
        return (written, skipped)
    }

    /// Applies writes as one transaction, creating the drive first if it doesn't exist and
    /// `createsDrive`.
    func apply(_ writes: [SpaceWrite]) async throws -> [String?] {
        do {
            return try await client.applySpaceWrites(space: space, repo: owner, writes: writes)
        } catch let error as XRPCError where error.error == "SpaceNotFound" && createsDrive {
            try await create()
            return try await client.applySpaceWrites(space: space, repo: owner, writes: writes)
        }
    }

    /// A write that failed because another device changed the same record first.
    static func isRace(_ error: XRPCError) -> Bool {
        error.error == "RecordAlreadyExists" || error.error == "RecordNotFound"
    }
}

/// What the change feed says happened since a revision (`Drive.changes(since:)`).
public struct DriveChanges: Sendable {
    /// Every write, in every collection, in order. An op's value is there only while its
    /// version is the record's current one, so ops that later ones replaced have none.
    public var ops: [RepoOp]
    /// The commit the drive is now at; `nil` if it has no repo (gone, or never written to).
    public var commit: RepoCommit?

    public init(ops: [RepoOp], commit: RepoCommit?) {
        self.ops = ops
        self.commit = commit
    }

    public var revision: String? { commit?.rev }
}

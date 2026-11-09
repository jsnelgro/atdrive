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

    public typealias Progress = @Sendable (_ bytesDone: Int, _ bytesTotal: Int) -> Void

    public init(
        client: XRPCClient, owner: String, key: String = Lexicon.defaultDriveKey,
        chunkSize: Int = 4 * 1024 * 1024
    ) {
        self.client = client
        self.owner = owner
        self.space = XRPCClient.spaceURI(authority: owner, type: Lexicon.driveSpace, key: key)
        self.chunkSize = chunkSize
    }

    /// Opens the logged-in account's drive.
    public convenience init(session: SessionManager, transport: any HTTPTransport = URLSessionTransport())
        async
    {
        let current = await session.session
        self.init(
            client: XRPCClient(service: current.service, session: session, transport: transport),
            owner: current.did)
    }

    // MARK: Reading

    /// Every file and folder in the drive. An empty drive (or one never written to) is empty.
    public func tree() async throws -> DriveTree {
        var nodes: [Node] = []
        var cursor: String?
        repeat {
            let page: XRPCClient.SpaceRecordPage<NodeRecord>
            do {
                page = try await client.listSpaceRecords(
                    space: space, repo: owner, collection: Lexicon.node, cursor: cursor,
                    as: NodeRecord.self)
            } catch let error as XRPCError
                where error.error == "SpaceNotFound" || error.error == "RepoNotFound"
            {
                return DriveTree([])
            }
            nodes += page.records.compactMap { record in
                // Skip records we can't read, or whose names could escape a local folder
                // (e.g. "..") when downloaded. Our own writes never produce these.
                guard let value = record.value, (try? DrivePath.validate(name: value.name)) != nil else {
                    return nil
                }
                return Node(id: record.rkey, cid: record.cid, record: value)
            }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return DriveTree(nodes)
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
    /// written. Cheap: use it to check for changes before listing everything with `tree()`.
    public func latestRevision() async throws -> String? {
        try await client.latestSpaceRevision(space: space, repo: owner)
    }

    // MARK: Writing

    /// Creates the drive's space. Writes do this automatically the first time.
    public func create() async throws {
        do {
            _ = try await client.createPersonalSpace(type: Lexicon.driveSpace, key: spaceKey)
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {}
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String?) async throws -> Node {
        try DrivePath.validate(name: name)
        return try await write(id: TID.next(), NodeRecord(name: name, parent: parent, kind: .folder))
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
        if let existing { record.createdAt = existing.record.createdAt }
        return try await write(id: existing?.id ?? TID.next(), record)
    }

    /// Whether a local file has the same contents as a file in the drive.
    public func isUnchanged(_ file: URL, comparedTo node: Node) throws -> Bool {
        guard !node.isFolder, let size = node.record.size, let sha256 = node.record.sha256,
            (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue == size
        else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().hexString == sha256
    }

    /// Renames and/or moves a file or folder. Folders move with everything inside them.
    @discardableResult
    public func move(_ node: Node, to parent: String?, as name: String) async throws -> Node {
        try DrivePath.validate(name: name)
        var record = node.record
        record.parent = parent
        record.name = name
        return try await write(id: node.id, record)
    }

    /// Deletes files and folders. To delete a folder's contents too, include them (see
    /// `DriveTree.descendants`), deepest first, so an interrupted delete leaves no orphans.
    public func delete(_ nodes: [Node]) async throws {
        try await client.deleteSpaceRecords(
            space: space, repo: owner, collection: Lexicon.node, rkeys: nodes.map(\.id))
    }

    private var spaceKey: String { String(space.split(separator: "/").last!) }

    private func write(id: String, _ record: NodeRecord) async throws -> Node {
        func put() async throws -> String {
            try await client.putSpaceRecord(
                space: space, repo: owner, collection: Lexicon.node, rkey: id, record: record)
        }
        do {
            return Node(id: id, cid: try await put(), record: record)
        } catch let error as XRPCError where error.error == "SpaceNotFound" {
            try await create()
            return Node(id: id, cid: try await put(), record: record)
        }
    }
}

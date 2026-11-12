import Crypto
import Foundation

/// A drive: one atproto space holding one record per file or folder, with file contents
/// stored as chunked blobs. Everything here works by node ID; `DriveTree` maps paths to IDs.
///
/// Everything is encrypted with the drive key before it leaves the device: records are sealed
/// (`SealedNode`) and every chunk is encrypted, so the PDS stores only what it can't read.
public final class Drive: Sendable {
    public let client: XRPCClient
    /// DID of the account that owns the drive (and, for now, the only one writing to it).
    public let owner: String
    /// The space's URI.
    public let space: String
    /// Files are split into chunks of this size (each stored as a blob, a little bigger once
    /// encrypted).
    public let chunkSize: Int
    let driveKey: DriveKey

    public typealias Progress = @Sendable (_ bytesDone: Int, _ bytesTotal: Int) -> Void

    public init(
        client: XRPCClient, owner: String, driveKey: DriveKey, key: String = Lexicon.defaultDriveKey,
        chunkSize: Int = 4 * 1024 * 1024
    ) {
        self.client = client
        self.owner = owner
        self.driveKey = driveKey
        self.space = XRPCClient.spaceURI(authority: owner, type: Lexicon.driveSpace, key: key)
        self.chunkSize = chunkSize
    }

    /// Opens the logged-in account's drive. Throws `locked` if this device hasn't unlocked it.
    public convenience init(session: SessionManager, transport: any HTTPTransport = URLSessionTransport())
        async throws
    {
        let current = await session.session
        guard let driveKey = current.driveKey else { throw ATDriveError.locked }
        self.init(
            client: XRPCClient(service: current.service, session: session, transport: transport),
            owner: current.did, driveKey: try DriveKey(rawValue: driveKey))
    }

    // MARK: Reading

    /// Every file and folder in the drive. An empty drive (or one never written to) is empty.
    ///
    /// Throws if any record can't be decrypted, rather than leaving it out: to `atdrive sync`
    /// or Finder, a missing item looks deleted, and they'd delete their copy.
    public func tree() async throws -> DriveTree {
        var nodes: [Node] = []
        var otherKey = 0
        var damaged = 0
        var newer = 0
        var plaintext = 0
        for record in try await storedNodes() {
            switch record.value {
            case .sealed(let sealed)?:
                do {
                    let value = try sealed.open(with: driveKey, context: context(record.rkey))
                    // Skip names that could escape a local folder (e.g. "..") when downloaded.
                    // Our own writes never produce these.
                    guard (try? DrivePath.validate(name: value.name)) != nil else { continue }
                    nodes.append(Node(id: record.rkey, cid: record.cid, record: value))
                } catch {
                    if sealed.keyID != driveKey.id {
                        otherKey += 1
                    } else if (try? driveKey.open(sealed.sealed, context: context(record.rkey))) == nil {
                        damaged += 1
                    } else {
                        newer += 1  // decrypted, but not something this version understands
                    }
                }
            case .plaintext?: plaintext += 1
            case nil: continue  // not a record this version understands
            }
        }
        if otherKey > 0 {
            throw ATDriveError.encryption(
                "\(otherKey) item(s) in your drive were encrypted with a different key than this device has. "
                    + "Sign in again (`atdrive login <handle>`) to get the current key.")
        }
        if damaged > 0 {
            throw ATDriveError.encryption(
                "\(damaged) item(s) in your drive can't be decrypted: they were changed on the server.")
        }
        if newer > 0 {
            throw ATDriveError.encryption(
                "\(newer) item(s) in your drive were saved by a newer version of ATDrive. Update ATDrive.")
        }
        if plaintext > 0 {
            throw ATDriveError.encryption(
                "\(plaintext) item(s) in your drive were saved before ATDrive encrypted drives. "
                    + "Sign in again (`atdrive login <handle>`) to encrypt them.")
        }
        return DriveTree(nodes)
    }

    /// Every node record as stored, unopened.
    func storedNodes() async throws -> [XRPCClient.SpaceRecordPage<StoredNode>.Record] {
        var records: [XRPCClient.SpaceRecordPage<StoredNode>.Record] = []
        var cursor: String?
        repeat {
            let page: XRPCClient.SpaceRecordPage<StoredNode>
            do {
                page = try await client.listSpaceRecords(
                    space: space, repo: owner, collection: Lexicon.node, cursor: cursor, as: StoredNode.self)
            } catch let error as XRPCError
                where error.error == "SpaceNotFound" || error.error == "RepoNotFound"
            {
                return []
            }
            records += page.records
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return records
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
            let data = try await fetch(chunk, of: node.name, encrypted: true)
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
        try await client.createDriveSpace(space)
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
            chunks.append(try await store(chunk: data, of: name))
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

    /// Renames and/or moves a file or folder. Folders move with everything inside them.
    @discardableResult
    public func move(_ node: Node, to parent: String?, as name: String) async throws -> Node {
        try DrivePath.validate(name: name)
        var record = node.record
        record.parent = parent
        record.name = name
        return try await write(id: node.id, record)
    }

    /// Writes a node back under its own ID, e.g. a folder deleted elsewhere that something is
    /// being added to here (see `ConflictRules`). Its contents, if a file, must still exist.
    @discardableResult
    public func restore(_ node: Node) async throws -> Node {
        try DrivePath.validate(name: node.name)
        return try await write(id: node.id, node.record)
    }

    /// Deletes files and folders. To delete a folder's contents too, include them (see
    /// `DriveTree.descendants`), deepest first, so an interrupted delete leaves no orphans.
    public func delete(_ nodes: [Node]) async throws {
        try await client.deleteSpaceRecords(
            space: space, repo: owner, collection: Lexicon.node, rkeys: nodes.map(\.id))
    }

    /// Encrypts the drive's items saved before ATDrive encrypted drives: their records are
    /// sealed and their contents uploaded again, encrypted. Once nothing references the old,
    /// unencrypted chunks, the PDS deletes them. Safe to interrupt: each item is done in one
    /// write, and what's left is done next time. Returns how many items it encrypted.
    @discardableResult
    public func encryptOlderItems(progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil)
        async throws -> Int
    {
        let older = try await storedNodes().compactMap { record -> (String, NodeRecord)? in
            guard case .plaintext(let value)? = record.value else { return nil }
            return (record.rkey, value)
        }
        for (index, (id, old)) in older.enumerated() {
            progress?(index, older.count)
            var record = old
            if old.kind == .file {
                var hasher = SHA256()
                var chunks: [BlobRef] = []
                for chunk in old.chunks ?? [] {
                    let data = try await fetch(chunk, of: old.name, encrypted: false)
                    hasher.update(data: data)
                    chunks.append(try await store(chunk: data, of: old.name))
                }
                if let expected = old.sha256, hasher.finalize().hexString != expected {
                    throw ATDriveError.integrity("\(old.name) doesn't match its SHA-256")
                }
                record.chunks = chunks
            }
            _ = try await write(id: id, record)
        }
        progress?(older.count, older.count)
        return older.count
    }

    /// Fetches a chunk, checks it against its CID, and decrypts it.
    private func fetch(_ chunk: BlobRef, of name: String, encrypted: Bool) async throws -> Data {
        let data = try await client.getSpaceBlob(space: space, repo: owner, cid: chunk.cid)
        guard CID.forBlob(data) == chunk.cid else {
            throw ATDriveError.integrity("chunk \(chunk.cid) of \(name) doesn't match its CID")
        }
        guard encrypted else { return data }
        do {
            return try driveKey.decrypt(chunk: data)
        } catch {
            throw ATDriveError.integrity("chunk \(chunk.cid) of \(name) can't be decrypted")
        }
    }

    /// Encrypts and uploads a chunk, checking the server stored exactly that.
    private func store(chunk data: Data, of name: String) async throws -> BlobRef {
        let encrypted = driveKey.encrypt(chunk: data)
        let blob = try await client.uploadBlob(encrypted, mimeType: "application/octet-stream")
        guard blob.cid == CID.forBlob(encrypted), blob.size == encrypted.count else {
            throw ATDriveError.integrity("server stored a chunk of \(name) as \(blob.cid)")
        }
        return blob
    }

    /// What a sealed node record is bound to: this drive, its collection and its key.
    private func context(_ rkey: String) -> String { "\(space)/\(Lexicon.node)/\(rkey)" }

    private func write(id: String, _ record: NodeRecord) async throws -> Node {
        let sealed = SealedNode(record, key: driveKey, context: context(id))
        func put() async throws -> String {
            try await client.putSpaceRecord(
                space: space, repo: owner, collection: Lexicon.node, rkey: id, record: sealed)
        }
        do {
            return Node(id: id, cid: try await put(), record: record)
        } catch let error as XRPCError where error.error == "SpaceNotFound" {
            try await create()
            return Node(id: id, cid: try await put(), record: record)
        }
    }
}

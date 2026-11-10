import Foundation

/// How node, version, chunks and settings records are stored: only what the PDS needs stays
/// readable.
///
///     {"$type": "me.jsnelgro.atdrive.node",
///      "chunks": [{"$type": "blob", …}, …],
///      "sealed": {"keyID": "…", "sealed": {"$bytes": "…"}}}
///
/// - `chunks`: a file's chunks' blob refs, in order, so the PDS keeps the blobs while the record
///   references them. Absent for folders, deletes, and versions whose contents are in another.
///   Absent too when the list is too long for a record: it's then in `chunks` records
///   (`ChunksPayload`) of the version holding the contents, and the record says how many.
/// - `sealed`: everything else (`NodePayload`, `VersionPayload`, `ChunksPayload`,
///   `DriveSettings`), sealed with the keyring's current key for this collection and record key
///   (`Keyring.seal`), so it can't be read, changed, or moved to another record. It includes the
///   chunks' IDs, in the same order.
///
/// The in-memory types (`NodeRecord`, `VersionRecord`, `DriveSettings`) stay plaintext: `Drive`
/// seals on the way out and opens on the way in, and nothing else sees this.
struct SealedRecord: Encodable {
    var type: String
    var chunks: [BlobRef]?
    var sealed: SealedValue

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case chunks, sealed
    }

    /// Reads one from a stored value, or `nil` if it isn't one. Straight from the `JSONValue`,
    /// without a round trip through `JSONDecoder`: listing a drive reads every record.
    init?(_ value: JSONValue) {
        guard let type = value["$type"]?.string, let sealed = value["sealed"],
            let keyID = sealed["keyID"]?.string, let bytes = sealed["sealed"]?["$bytes"]?.string,
            let data = Base64.decode(bytes)
        else { return nil }
        self.type = type
        self.sealed = SealedValue(keyID: KeyID(rawValue: keyID), sealed: Bytes(data))
        switch value["chunks"] {
        case nil, .null?: chunks = nil
        case let list?:
            guard let refs = try? list.decode(as: [BlobRef].self) else { return nil }
            chunks = refs
        }
    }

    init(type: String, chunks: [BlobRef]?, sealed: SealedValue) {
        self.type = type
        self.chunks = chunks
        self.sealed = sealed
    }
}

/// The sealed part of a node record: all of `NodeRecord` but the chunks' blob refs, which stay
/// outside; their IDs are here instead, in the same order. A list in `chunks` records
/// (`continuations`) is in neither.
struct NodePayload: Codable {
    var name: String
    var parent: String?
    var kind: NodeRecord.Kind
    var size: Int?
    var sha256: String?
    var chunkIDs: [ChunkID]?
    var createdAt: String
    var modifiedAt: String?
    var version: String?
    var contentsFrom: String?
    var continuations: Int?

    init(_ record: NodeRecord) {
        name = record.name
        parent = record.parent
        kind = record.kind
        size = record.size
        sha256 = record.sha256
        chunkIDs = record.hasContinuations ? nil : record.chunks?.map(\.id)
        createdAt = record.createdAt
        modifiedAt = record.modifiedAt
        version = record.version
        contentsFrom = record.contentsFrom
        continuations = record.hasContinuations ? record.continuations : nil
    }

    /// The record, its chunks put back together; `nil` if the blob refs beside it don't match
    /// the sealed IDs (the PDS changed them). Chunks in `chunks` records aren't in it yet.
    func record(chunks blobs: [BlobRef]?) -> NodeRecord? {
        guard let chunks = ChunkRef.pair(blobs, chunkIDs) else { return nil }
        var record = NodeRecord(name: name, parent: parent, kind: kind, size: size, sha256: sha256, chunks: chunks)
        record.createdAt = createdAt
        record.modifiedAt = modifiedAt
        record.version = version
        record.contentsFrom = contentsFrom
        record.continuations = continuations
        return record
    }
}

/// The sealed part of a version record: all of `VersionRecord` but the chunks' blob refs.
struct VersionPayload: Codable {
    var node: String
    var change: VersionRecord.Change
    var device: String
    var prev: String?
    var name: String?
    var parent: String?
    var kind: NodeRecord.Kind?
    var size: Int?
    var sha256: String?
    var createdAt: String?
    var modifiedAt: String?
    var contentsFrom: String?
    var chunkIDs: [ChunkID]?
    var continuations: Int?

    init(_ record: VersionRecord) {
        node = record.node
        change = record.change
        device = record.device
        prev = record.prev
        name = record.name
        parent = record.parent
        kind = record.kind
        size = record.size
        sha256 = record.sha256
        createdAt = record.createdAt
        modifiedAt = record.modifiedAt
        contentsFrom = record.contentsFrom
        chunkIDs = record.hasContinuations ? nil : record.chunks?.map(\.id)
        continuations = record.hasContinuations ? record.continuations : nil
    }

    /// A change other than a delete always says what the node became.
    var isValid: Bool { change == .deleted || (name != nil && kind != nil) }

    func record(chunks blobs: [BlobRef]?) -> VersionRecord? {
        guard let chunks = ChunkRef.pair(blobs, chunkIDs) else { return nil }
        var record = VersionRecord(
            node: node, change: change, device: device, prev: prev, state: nil, holdsContents: false)
        record.name = name
        record.parent = parent
        record.kind = kind
        record.size = size
        record.sha256 = sha256
        record.createdAt = createdAt
        record.modifiedAt = modifiedAt
        record.contentsFrom = contentsFrom
        record.chunks = chunks
        record.continuations = continuations
        return record
    }
}

/// The sealed part of a `chunks` record: the IDs of the chunks whose blob refs are beside it, in
/// the same order. Its key (`Lexicon.continuationKey`) says whose list it continues, and where.
struct ChunksPayload: Codable {
    var chunkIDs: [ChunkID]
}

extension NodeRecord {
    /// Whether the chunk list is in `chunks` records rather than in the record.
    var hasContinuations: Bool { kind == .file && (continuations ?? 0) > 0 }
}

extension VersionRecord {
    /// Whether this version holds its chunk list in `chunks` records rather than in the record.
    var hasContinuations: Bool { contentsFrom == nil && (continuations ?? 0) > 0 }
}

extension ChunkRef {
    /// Blob refs and chunk IDs, matched up in order: `.some(nil)` if there are neither, and `nil`
    /// if one is missing or they don't have the same length.
    static func pair(_ blobs: [BlobRef]?, _ ids: [ChunkID]?) -> [ChunkRef]?? {
        switch (blobs, ids) {
        case (nil, nil): return .some(nil)
        case (let blobs?, let ids?) where blobs.count == ids.count:
            return .some(zip(blobs, ids).map { ChunkRef(blob: $0, id: $1) })
        default: return nil
        }
    }
}

/// A version record as read from the drive: a `Version`, or one this device can't read.
public enum VersionEntry: Sendable, Equatable {
    case readable(Version)
    case unreadable(UnreadableVersion)

    public var id: String {
        switch self {
        case .readable(let version): version.id
        case .unreadable(let record): record.id
        }
    }
}

extension Drive {
    // MARK: Reading sealed records

    /// The one place a stored node record becomes a `Node`, for listings and the change feed
    /// alike. A record that can't be read is unreadable rather than dropped, so it can't look
    /// deleted: one sealed with a key this device doesn't have (`missingKey`), one that doesn't
    /// open (`tampered`: changed, or moved from another record), one that doesn't decode (a
    /// newer format), and one whose name could escape a local folder (e.g. `..`) when
    /// downloaded. Our own writes never produce the last two.
    ///
    /// `continuations` are the `chunks` records by key, for a file whose chunk list is in them;
    /// one that's missing makes it unreadable (`incomplete`).
    public func readNode(id: String, cid: String, value: JSONValue?, continuations: [String: JSONValue] = [:])
        -> NodeEntry
    {
        let record: NodeRecord
        do {
            let (payload, chunks) = try unseal(value, as: NodePayload.self, collection: Lexicon.node, rkey: id)
            guard var unsealed = payload.record(chunks: chunks) else { throw Unreadable(reason: .tampered) }
            if unsealed.hasContinuations {
                guard chunks == nil, let holder = unsealed.contentsFrom else { throw Unreadable(reason: .tampered) }
                unsealed.chunks = try readContinuations(
                    of: holder, count: unsealed.continuations ?? 0, in: continuations)
            }
            record = unsealed
        } catch {
            let reason = (error as? Unreadable)?.reason ?? .newerFormat
            return .unreadable(UnreadableNode(id: id, cid: cid, reason: reason, value: value))
        }
        guard (try? DrivePath.validate(name: record.name)) != nil else {
            return .unreadable(UnreadableNode(id: id, cid: cid, reason: .invalidName, value: value))
        }
        return .readable(Node(id: id, cid: cid, record: record))
    }

    /// The one place a stored version record becomes a `Version` (see `readNode`).
    public func readVersion(id: String, cid: String, value: JSONValue?, continuations: [String: JSONValue] = [:])
        -> VersionEntry
    {
        do {
            let (payload, chunks) = try unseal(value, as: VersionPayload.self, collection: Lexicon.version, rkey: id)
            guard payload.isValid else { throw Unreadable(reason: .newerFormat) }
            guard var record = payload.record(chunks: chunks) else { throw Unreadable(reason: .tampered) }
            if record.hasContinuations {
                guard chunks == nil else { throw Unreadable(reason: .tampered) }
                record.chunks = try readContinuations(of: id, count: record.continuations ?? 0, in: continuations)
            }
            return .readable(Version(id: id, cid: cid, record: record))
        } catch {
            let reason = (error as? Unreadable)?.reason ?? .newerFormat
            return .unreadable(UnreadableVersion(id: id, cid: cid, reason: reason, value: value))
        }
    }

    /// The drive's settings from their stored record, or `nil` if it can't be read here. A
    /// plaintext one, or one sealed with a key that isn't the drive's, is ignored: the defaults
    /// apply, so a forged retention can't make devices prune history. `keyring` is this drive's
    /// unless given.
    public func readSettings(_ value: JSONValue?, with keyring: Keyring? = nil) -> DriveSettings? {
        try? unseal(
            value, as: DriveSettings.self, collection: Lexicon.settings, rkey: Lexicon.settingsKey,
            with: keyring
        ).payload
    }

    private struct Unreadable: Error {
        var reason: UnreadableNode.Reason
    }

    /// A chunk list from a version's `chunks` records, put together in order.
    private func readContinuations(of version: String, count: Int, in records: [String: JSONValue]) throws
        -> [ChunkRef]
    {
        var chunks: [ChunkRef] = []
        for index in 1...max(count, 1) {
            let key = Lexicon.continuationKey(of: version, index)
            guard let value = records[key] else { throw Unreadable(reason: .incomplete) }
            let (payload, blobs) = try unseal(value, as: ChunksPayload.self, collection: Lexicon.chunks, rkey: key)
            guard let paired = ChunkRef.pair(blobs, payload.chunkIDs), let part = paired else {
                throw Unreadable(reason: .tampered)
            }
            chunks += part
        }
        return chunks
    }

    /// Opens a stored record's sealed payload, and gives the blob refs beside it. Throws
    /// `Unreadable`.
    private func unseal<Payload: Decodable>(
        _ value: JSONValue?, as type: Payload.Type, collection: String, rkey: String, with keyring: Keyring? = nil
    ) throws -> (payload: Payload, chunks: [BlobRef]?) {
        guard let value, let stored = SealedRecord(value) else { throw Unreadable(reason: .newerFormat) }
        guard let keyring = keyring ?? self.keyring else { throw Unreadable(reason: .missingKey) }
        do {
            return (try keyring.open(stored.sealed, as: type, collection: collection, rkey: rkey), stored.chunks)
        } catch DriveCryptoError.unknownKeyID {
            throw Unreadable(reason: .missingKey)
        } catch DriveCryptoError.authenticationFailed {
            throw Unreadable(reason: .tampered)
        } catch {
            throw Unreadable(reason: .newerFormat)  // authentic, so written by a newer version
        }
    }

    // MARK: Sealing records

    /// A node record as it's stored.
    func stored(_ record: NodeRecord, id: String) throws -> JSONValue {
        try seal(
            NodePayload(record), collection: Lexicon.node, rkey: id,
            chunks: record.hasContinuations ? nil : record.chunks?.map(\.blob))
    }

    /// A version record as it's stored.
    func stored(_ record: VersionRecord, id: String) throws -> JSONValue {
        try seal(
            VersionPayload(record), collection: Lexicon.version, rkey: id,
            chunks: record.hasContinuations ? nil : record.chunks?.map(\.blob))
    }

    /// A `chunks` record as it's stored: one part of a version's chunk list.
    func stored(_ part: [ChunkRef], key: String) throws -> JSONValue {
        try seal(
            ChunksPayload(chunkIDs: part.map(\.id)), collection: Lexicon.chunks, rkey: key, chunks: part.map(\.blob))
    }

    /// A chunk list cut into parts for `chunks` records of at most `limit` bytes each (as
    /// `storedSize` counts), in order; none if the whole list fits in one record.
    static func continuationParts(of chunks: [ChunkRef], limit: Int) -> [[ChunkRef]] {
        let sizes = chunks.map(storedSize)
        guard sizes.reduce(0, +) > limit else { return [] }
        var parts: [[ChunkRef]] = []
        var part: [ChunkRef] = []
        var size = 0
        for (chunk, added) in zip(chunks, sizes) {
            if !part.isEmpty, size + added > limit {
                parts.append(part)
                part = []
                size = 0
            }
            part.append(chunk)
            size += added
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }

    /// About how many bytes a chunk adds to a stored record: its blob ref
    /// (`{"$type":"blob","ref":{"$link":"…"},"mimeType":"…","size":…},`) and its ID in the sealed
    /// part (`"…",`: 43 characters of base64, then base64 again, sealed).
    static func storedSize(of chunk: ChunkRef) -> Int {
        let blob = 60 + chunk.blob.cid.utf8.count + chunk.blob.mimeType.utf8.count + String(chunk.blob.size).utf8.count
        return blob + 62
    }

    /// The settings record as it's stored.
    func stored(_ settings: DriveSettings, with keyring: Keyring) throws -> JSONValue {
        try seal(settings, collection: Lexicon.settings, rkey: Lexicon.settingsKey, chunks: nil, with: keyring)
    }

    /// Seals with the current key, which throws `DriveAccessError.locked` if this device doesn't
    /// have the drive's keys.
    private func seal<Payload: Encodable>(
        _ payload: Payload, collection: String, rkey: String, chunks: [BlobRef]?, with keyring: Keyring? = nil
    ) throws -> JSONValue {
        guard let keyring = keyring ?? self.keyring else { throw DriveAccessError.locked }
        let sealed = try keyring.seal(payload, collection: collection, rkey: rkey)
        return try JSONValue(encoding: SealedRecord(type: collection, chunks: chunks, sealed: sealed))
    }
}

import Foundation

/// How node, version, chunks and settings records are stored. Each record says for itself
/// whether it's plain or sealed, so a drive can hold both while encryption is being turned on or
/// off, and every reader can read either.
///
/// Plain, on a drive that isn't encrypted:
///
///     {"$type": "app.atdrive.node",
///      "name": "notes.txt", "kind": "file", "size": 42, "sha256": "…", …,
///      "chunks": [{"$type": "blob", …}, …]}
///
/// Sealed, on an encrypted drive, where only what the PDS needs stays readable:
///
///     {"$type": "app.atdrive.node",
///      "chunks": [{"$type": "blob", …}, …],
///      "sealed": {"keyID": "…", "sealed": {"$bytes": "…"}}}
///
/// - `chunks`: a file's chunks' blob refs, in order, so the PDS keeps the blobs while the record
///   references them. Absent for folders, deletes, and versions whose contents are in another.
///   Absent too when the list is too long for a record: it's then in `chunks` records
///   (`ChunksPayload`) of the version holding the contents, and the record says how many.
/// - Everything else (`NodePayload`, `VersionPayload`, `ChunksPayload`, `DriveSettings`) is
///   beside them in a plain record, and in `sealed` in a sealed one: encrypted with the keyring's
///   current key for this space, collection and record key (`Keyring.seal`), so it can't be read,
///   changed, or moved to another record. It includes the IDs of encrypted chunks, in the same
///   order, and the key they were made with.
///
/// The in-memory types (`NodeRecord`, `VersionRecord`, `DriveSettings`) are the same either way:
/// `Drive` picks the form on the way out (`Drive.mode`) and reads either on the way in, and
/// nothing else sees this.
struct SealedRecord: Encodable {
    var type: String
    var chunks: [BlobRef]?
    var sealed: SealedValue

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case chunks, sealed
    }

    /// Reads one from a stored value, or `nil` if it isn't sealed. Straight from the `JSONValue`,
    /// without a round trip through `JSONDecoder`: listing a drive reads every record.
    init?(_ value: JSONValue) {
        guard let type = value["$type"]?.string, let sealed = value["sealed"],
            let keyID = sealed["keyID"]?.string, let bytes = sealed["sealed"]?["$bytes"]?.string,
            let data = Base64.decode(bytes)
        else { return nil }
        self.type = type
        self.sealed = SealedValue(keyID: KeyID(rawValue: keyID), sealed: Bytes(data))
        guard let chunks = Self.blobs(beside: value) else { return nil }
        self.chunks = chunks
    }

    init(type: String, chunks: [BlobRef]?, sealed: SealedValue) {
        self.type = type
        self.chunks = chunks
        self.sealed = sealed
    }

    /// The blob refs in a stored record's `chunks`: `.some(nil)` if it has none, and `nil` if
    /// they aren't blob refs.
    static func blobs(beside value: JSONValue) -> [BlobRef]?? {
        switch value["chunks"] {
        case nil, .null?: return .some(nil)
        case let list?:
            guard let refs = try? list.decode(as: [BlobRef].self) else { return nil }
            return .some(refs)
        }
    }

    /// Whether a stored value has a `sealed` part at all (even one that can't be read).
    static func isSealed(_ value: JSONValue?) -> Bool {
        guard let sealed = value?["sealed"], case .object = sealed else { return false }
        return true
    }
}

/// How a record was stored, as far as it matters for trusting it.
enum StoredForm: Equatable {
    /// Sealed with one of the drive's current keys.
    case sealed(KeyID)
    /// Sealed with a retired key (`DriveSettings.retiredKeys`): readable by the PDS.
    case retired(KeyID)
    case plain

    var isCurrent: Bool {
        if case .sealed = self { return true }
        return false
    }
}

/// A record's chunk IDs and the key they were made with, as stored beside its other fields.
/// Either every chunk of a record is encrypted, or none is: a chunk list is stored whole.
private func chunkKeys(of chunks: [ChunkRef]?) throws -> (ids: [ChunkID]?, key: KeyID?) {
    guard let chunks, chunks.contains(where: \.isEncrypted) else { return (nil, nil) }
    let ids = chunks.compactMap(\.id)
    let keys = Set(chunks.map(\.key))
    guard ids.count == chunks.count, keys.count == 1 else {
        throw ATDriveError.integrity("a chunk list mixes chunks encrypted in different ways")
    }
    return (ids, chunks[0].key)
}

/// Everything in a node record but the chunks' blob refs: all of `NodeRecord`, with the IDs of
/// encrypted chunks in the same order as the blob refs. A list in `chunks` records
/// (`continuations`) is in neither.
struct NodePayload: Codable {
    var name: String
    var parent: String?
    var kind: NodeRecord.Kind
    var size: Int?
    var sha256: String?
    var chunkIDs: [ChunkID]?
    var chunkKey: KeyID?
    var createdAt: String
    var modifiedAt: String?
    var version: String?
    var contentsFrom: String?
    var continuations: Int?
    var continuationsFrom: Int?
    var mount: MountInfo?

    init(_ record: NodeRecord) throws {
        name = record.name
        parent = record.parent
        kind = record.kind
        size = record.size
        sha256 = record.sha256
        if !record.hasContinuations { (chunkIDs, chunkKey) = try chunkKeys(of: record.chunks) }
        createdAt = record.createdAt
        modifiedAt = record.modifiedAt
        version = record.version
        contentsFrom = record.contentsFrom
        continuations = record.hasContinuations ? record.continuations : nil
        continuationsFrom = record.hasContinuations ? record.continuationsFrom : nil
        mount = record.kind == .mount ? record.mount : nil
    }

    /// The record, its chunks put back together; `nil` if the blob refs beside it don't match
    /// the chunk IDs (the PDS changed them). Chunks in `chunks` records aren't in it yet.
    func record(chunks blobs: [BlobRef]?) -> NodeRecord? {
        guard let chunks = ChunkRef.pair(blobs, chunkIDs, key: chunkKey) else { return nil }
        var record = NodeRecord(name: name, parent: parent, kind: kind, size: size, sha256: sha256, chunks: chunks)
        record.createdAt = createdAt
        record.modifiedAt = modifiedAt
        record.version = version
        record.contentsFrom = contentsFrom
        record.continuations = continuations
        record.continuationsFrom = continuationsFrom
        record.mount = kind == .mount ? mount : nil
        if kind == .mount, mount == nil { return nil }
        return record
    }
}

/// Everything in a version record but the chunks' blob refs.
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
    var chunkKey: KeyID?
    var continuations: Int?
    var continuationsFrom: Int?
    var mount: MountInfo?

    init(_ record: VersionRecord) throws {
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
        if !record.hasContinuations { (chunkIDs, chunkKey) = try chunkKeys(of: record.chunks) }
        continuations = record.hasContinuations ? record.continuations : nil
        continuationsFrom = record.hasContinuations ? record.continuationsFrom : nil
        mount = record.kind == .mount ? record.mount : nil
    }

    /// A change other than a delete always says what the node became.
    var isValid: Bool {
        change == .deleted || change == .shared || (name != nil && kind != nil && (kind != .mount || mount != nil))
    }

    func record(chunks blobs: [BlobRef]?) -> VersionRecord? {
        guard let chunks = ChunkRef.pair(blobs, chunkIDs, key: chunkKey) else { return nil }
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
        record.continuationsFrom = continuationsFrom
        record.mount = mount
        return record
    }
}

/// Everything in a `chunks` record but the blob refs: the IDs of those chunks, if they're
/// encrypted, in the same order. Its key (`Lexicon.continuationKey`) says whose list it
/// continues, and where.
struct ChunksPayload: Codable {
    var chunkIDs: [ChunkID]?
    var chunkKey: KeyID?

    init(_ part: [ChunkRef]) throws {
        (chunkIDs, chunkKey) = try chunkKeys(of: part)
    }
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
    /// Blob refs and chunk IDs, matched up in order. No IDs means plain chunks. `.some(nil)` if
    /// there are no blobs either, and `nil` if there are IDs without blobs, or not one per blob.
    static func pair(_ blobs: [BlobRef]?, _ ids: [ChunkID]?, key: KeyID?) -> [ChunkRef]?? {
        switch (blobs, ids) {
        case (nil, nil): return .some(nil)
        case (let blobs?, nil): return .some(blobs.map { ChunkRef(blob: $0) })
        case (let blobs?, let ids?) where blobs.count == ids.count:
            return .some(zip(blobs, ids).map { ChunkRef(blob: $0, id: $1, key: key) })
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
    // MARK: Reading stored records

    /// The one place a stored node record becomes a `Node`, for listings and the change feed
    /// alike. A record that can't be read is unreadable rather than dropped, so it can't look
    /// deleted: one sealed with a key this device doesn't have (`missingKey`), one that doesn't
    /// open (`tampered`: changed, or moved from another record), one that isn't sealed with the
    /// drive's keys though the drive is encrypted (`notSealed`: the PDS could have written it),
    /// one that doesn't decode (a newer format), and one whose name could escape a local folder
    /// (e.g. `..`) when downloaded. Our own writes never produce the last two.
    ///
    /// `continuations` are the `chunks` records by key, for a file whose chunk list is in them;
    /// one that's missing makes it unreadable (`incomplete`).
    public func readNode(id: String, cid: String, value: JSONValue?, continuations: [String: JSONValue] = [:])
        -> NodeEntry
    {
        let record: NodeRecord
        do {
            let (payload, chunks, _) = try unseal(value, as: NodePayload.self, collection: Lexicon.node, rkey: id)
            guard var unsealed = payload.record(chunks: chunks) else { throw Unreadable(reason: .tampered) }
            if unsealed.hasContinuations {
                guard chunks == nil, let holder = unsealed.contentsFrom else { throw Unreadable(reason: .tampered) }
                unsealed.chunks = try readContinuations(
                    of: holder, from: unsealed.continuationsFrom, count: unsealed.continuations ?? 0,
                    in: continuations)
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
            let (payload, chunks, _) = try unseal(
                value, as: VersionPayload.self, collection: Lexicon.version, rkey: id)
            guard payload.isValid else { throw Unreadable(reason: .newerFormat) }
            guard var record = payload.record(chunks: chunks) else { throw Unreadable(reason: .tampered) }
            if record.hasContinuations {
                guard chunks == nil else { throw Unreadable(reason: .tampered) }
                record.chunks = try readContinuations(
                    of: id, from: record.continuationsFrom, count: record.continuations ?? 0, in: continuations)
            }
            return .readable(Version(id: id, cid: cid, record: record))
        } catch {
            let reason = (error as? Unreadable)?.reason ?? .newerFormat
            return .unreadable(UnreadableVersion(id: id, cid: cid, reason: reason, value: value))
        }
    }

    /// The drive's settings from their stored record, as this drive reads its records (see
    /// `unseal`); `nil` if they can't be read here. On an encrypted drive, a plain one, or one
    /// sealed with a key that isn't the drive's, is ignored: the defaults apply, so a forged
    /// retention can't make devices prune history.
    public func readSettings(_ value: JSONValue?) -> DriveSettings? {
        try? unseal(value, as: DriveSettings.self, collection: Lexicon.settings, rkey: Lexicon.settingsKey).payload
    }

    /// The settings as their record stores them, read with `keyring` if they're sealed, whatever
    /// this drive's mode: for working out the mode in the first place (`open`).
    func settings(stored value: JSONValue?, keyring: Keyring?) -> DriveSettings? {
        guard let value else { return nil }
        if let stored = SealedRecord(value) {
            return try? keyring?.open(
                stored.sealed, as: DriveSettings.self, space: space, collection: Lexicon.settings,
                rkey: Lexicon.settingsKey)
        }
        return try? value.decode(as: DriveSettings.self)
    }

    private struct Unreadable: Error {
        var reason: UnreadableNode.Reason
    }

    /// A chunk list from a version's `chunks` records, put together in order.
    private func readContinuations(of version: String, from first: Int?, count: Int, in records: [String: JSONValue])
        throws -> [ChunkRef]
    {
        var chunks: [ChunkRef] = []
        let first = max(first ?? 1, 1)
        for index in first..<(first + max(count, 1)) {
            let key = Lexicon.continuationKey(of: version, index)
            guard let value = records[key] else { throw Unreadable(reason: .incomplete) }
            let (payload, blobs, _) = try unseal(value, as: ChunksPayload.self, collection: Lexicon.chunks, rkey: key)
            guard let paired = ChunkRef.pair(blobs, payload.chunkIDs, key: payload.chunkKey), let part = paired else {
                throw Unreadable(reason: .tampered)
            }
            chunks += part
        }
        return chunks
    }

    /// Reads a stored record, plain or sealed: its payload, the blob refs beside it, and how it
    /// was stored. Throws `Unreadable`.
    ///
    /// A sealed record opens with the drive's keyring, or with its retired keys (published when
    /// encryption was turned off). On an encrypted drive, a record that's plain or sealed with a
    /// retired key is one the PDS could have written, so it's read only while the drive says
    /// such records are still being encrypted (`DriveSettings.converting`).
    func unseal<Payload: Decodable>(_ value: JSONValue?, as type: Payload.Type, collection: String, rkey: String)
        throws -> (payload: Payload, chunks: [BlobRef]?, form: StoredForm)
    {
        guard let value else { throw Unreadable(reason: .newerFormat) }
        let keys = keys.value
        guard SealedRecord.isSealed(value) else {
            guard keys.acceptsUnsealed else { throw Unreadable(reason: .notSealed) }
            guard let payload = try? value.decode(as: type), let chunks = SealedRecord.blobs(beside: value) else {
                throw Unreadable(reason: .newerFormat)
            }
            return (payload, chunks, .plain)
        }
        guard let stored = SealedRecord(value) else { throw Unreadable(reason: .newerFormat) }
        let keyring: Keyring
        let form: StoredForm
        if let current = keys.keyring, current.key(id: stored.sealed.keyID) != nil {
            (keyring, form) = (current, .sealed(stored.sealed.keyID))
        } else if let retired = keys.retired, retired.key(id: stored.sealed.keyID) != nil {
            guard keys.acceptsUnsealed else { throw Unreadable(reason: .notSealed) }
            (keyring, form) = (retired, .retired(stored.sealed.keyID))
        } else {
            throw Unreadable(reason: .missingKey)
        }
        do {
            let payload = try keyring.open(stored.sealed, as: type, space: space, collection: collection, rkey: rkey)
            return (payload, stored.chunks, form)
        } catch DriveCryptoError.authenticationFailed {
            throw Unreadable(reason: .tampered)
        } catch {
            throw Unreadable(reason: .newerFormat)  // authentic, so written by a newer version
        }
    }

    /// How a record that reads here was stored; `nil` if it doesn't.
    func storedForm(of value: JSONValue?, collection: String, rkey: String) -> StoredForm? {
        struct Anything: Decodable {}
        return try? unseal(value, as: Anything.self, collection: collection, rkey: rkey).form
    }

    // MARK: Storing records

    /// Any other record of the drive's, as it's stored: sealed on an encrypted drive.
    func stored<Payload: Encodable>(_ payload: Payload, collection: String, rkey: String) throws -> JSONValue {
        try store(payload, collection: collection, rkey: rkey, chunks: nil)
    }

    /// Such a record, read back; `nil` if it doesn't read here.
    func read<Payload: Decodable>(_ value: JSONValue?, as type: Payload.Type, collection: String, rkey: String)
        -> Payload?
    {
        try? unseal(value, as: type, collection: collection, rkey: rkey).payload
    }

    /// A node record as it's stored. A mount holding a keyring is refused unless it's sealed: on a
    /// plain drive, the keyring would be readable.
    func stored(_ record: NodeRecord, id: String) throws -> JSONValue {
        if record.mount?.keyring != nil, mode != .encrypted { throw SharingError.keyringWouldBeReadable }
        return try store(
            NodePayload(record), collection: Lexicon.node, rkey: id,
            chunks: record.hasContinuations ? nil : record.chunks?.map(\.blob))
    }

    /// A version record as it's stored (see the node's).
    func stored(_ record: VersionRecord, id: String) throws -> JSONValue {
        var record = record
        if record.mount?.keyring != nil, mode != .encrypted {
            // History on a plain drive (being converted, say) keeps no keyring: readable, it
            // would protect nothing.
            record.mount?.keyring = nil
        }
        return try store(
            VersionPayload(record), collection: Lexicon.version, rkey: id,
            chunks: record.hasContinuations ? nil : record.chunks?.map(\.blob))
    }

    /// A `chunks` record as it's stored: one part of a version's chunk list.
    func stored(_ part: [ChunkRef], key: String) throws -> JSONValue {
        try store(ChunksPayload(part), collection: Lexicon.chunks, rkey: key, chunks: part.map(\.blob))
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
    /// (`{"$type":"blob","ref":{"$link":"…"},"mimeType":"…","size":…},`) and, if it's encrypted,
    /// its ID in the sealed part (`"…",`: 43 characters of base64, then base64 again, sealed).
    static func storedSize(of chunk: ChunkRef) -> Int {
        let blob = 60 + chunk.blob.cid.utf8.count + chunk.blob.mimeType.utf8.count + String(chunk.blob.size).utf8.count
        return blob + (chunk.isEncrypted ? 62 : 0)
    }

    /// The settings record as it's stored: sealed with `keyring`, or plain without one.
    func stored(_ settings: DriveSettings, with keyring: Keyring?) throws -> JSONValue {
        try Self.store(
            settings, space: space, collection: Lexicon.settings, rkey: Lexicon.settingsKey, chunks: nil,
            keyring: keyring)
    }

    /// A record as this drive stores it now: sealed with the current key on an encrypted drive
    /// (which throws `DriveAccessError.locked` if this device doesn't have the keys), plain
    /// otherwise. Throws `DriveAccessError.notOpened` before the drive knows which it is.
    private func store<Payload: Encodable>(_ payload: Payload, collection: String, rkey: String, chunks: [BlobRef]?)
        throws -> JSONValue
    {
        let keys = keys.value
        switch keys.mode {
        case nil: throw DriveAccessError.notOpened
        case .plain?:
            return try Self.store(
                payload, space: space, collection: collection, rkey: rkey, chunks: chunks, keyring: nil)
        case .encrypted?:
            guard let keyring = keys.keyring else { throw DriveAccessError.locked }
            return try Self.store(
                payload, space: space, collection: collection, rkey: rkey, chunks: chunks, keyring: keyring)
        }
    }

    private static func store<Payload: Encodable>(
        _ payload: Payload, space: String, collection: String, rkey: String, chunks: [BlobRef]?, keyring: Keyring?
    ) throws -> JSONValue {
        if let keyring {
            let sealed = try keyring.seal(payload, space: space, collection: collection, rkey: rkey)
            return try JSONValue(encoding: SealedRecord(type: collection, chunks: chunks, sealed: sealed))
        }
        guard case .object(var fields) = try JSONValue(encoding: payload) else {
            throw ATDriveError.integrity("a \(collection) record isn't an object")
        }
        fields["$type"] = .string(collection)
        if let chunks { fields["chunks"] = try JSONValue(encoding: chunks) }
        return .object(fields)
    }
}

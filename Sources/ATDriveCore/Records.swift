import Foundation

/// A reference to a blob, as it appears inside a record:
/// `{"$type": "blob", "ref": {"$link": "<cid>"}, "mimeType": "…", "size": 123}`
public struct BlobRef: Codable, Sendable, Hashable {
    public var cid: String
    public var mimeType: String
    public var size: Int

    public init(cid: String, mimeType: String, size: Int) {
        self.cid = cid
        self.mimeType = mimeType
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case ref, mimeType, size
    }

    private struct Link: Codable {
        var link: String
        enum CodingKeys: String, CodingKey { case link = "$link" }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try container.decode(Link.self, forKey: .ref).link
        mimeType = try container.decode(String.self, forKey: .mimeType)
        size = try container.decode(Int.self, forKey: .size)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("blob", forKey: .type)
        try container.encode(Link(link: cid), forKey: .ref)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(size, forKey: .size)
    }
}

/// One file or folder in a drive: the `me.jsnelgro.atdrive.node` record.
///
/// Files and folders reference their parent by ID rather than storing a path, so renaming or
/// moving anything (even a folder with thousands of files inside) is a single record update.
/// File contents are split into chunks, each stored as a blob, listed in order.
public struct NodeRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case file, folder
    }

    public var name: String
    /// Record key of the parent folder; `nil` means the top level of the drive.
    public var parent: String?
    public var kind: Kind
    /// Files only: total size in bytes.
    public var size: Int?
    /// Files only: hex SHA-256 of the whole file, checked after every download.
    public var sha256: String?
    /// Files only: the content, in order. Concatenated, they are the file.
    public var chunks: [BlobRef]?
    public var createdAt: String
    /// Files only: the file's own modification time, restored on download.
    public var modifiedAt: String?

    public init(
        name: String, parent: String?, kind: Kind, size: Int? = nil, sha256: String? = nil,
        chunks: [BlobRef]? = nil, createdAt: Date = Date(), modifiedAt: Date? = nil
    ) {
        self.name = name
        self.parent = parent
        self.kind = kind
        self.size = size
        self.sha256 = sha256
        self.chunks = chunks
        self.createdAt = Timestamp.format(createdAt)
        self.modifiedAt = modifiedAt.map(Timestamp.format)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case name, parent, kind, size, sha256, chunks, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        kind = try container.decode(Kind.self, forKey: .kind)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        chunks = try container.decodeIfPresent([BlobRef].self, forKey: .chunks)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(String.self, forKey: .modifiedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.node, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(chunks, forKey: .chunks)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
    }

    public var modifiedDate: Date? { modifiedAt.flatMap(Timestamp.parse) }
    public var createdDate: Date? { Timestamp.parse(createdAt) }
}

/// atproto `datetime` strings (RFC 3339, always UTC here).
enum Timestamp {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    static func format(_ date: Date) -> String { withFraction.format(date) }

    static func parse(_ string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? withoutFraction.parse(string))
    }
}

/// A node record as it's stored on the PDS: everything but the blob refs is sealed with the
/// drive key (`DriveKey.seal`), so the PDS can't read names, folders, sizes or hashes.
///
///     {"$type": "me.jsnelgro.atdrive.node", "keyID": "…",
///      "sealed": {"$bytes": "…"}, "chunks": [{"$type": "blob", …}, …]}
///
/// `chunks` stays readable because the PDS keeps a blob only while a record references it. The
/// sealed part lists the same chunks' CIDs, so they can't be swapped for another file's.
/// `NodeRecord` stays the in-memory type: `Drive` seals on the way out and opens on the way in.
struct SealedNode: Codable, Sendable {
    /// `DriveKey.id` of the key it was sealed with.
    var keyID: String
    var sealed: Data
    var chunks: [BlobRef]?

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case keyID, sealed, chunks
    }

    init(keyID: String, sealed: Data, chunks: [BlobRef]?) {
        self.keyID = keyID
        self.sealed = sealed
        self.chunks = chunks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyID = try container.decode(String.self, forKey: .keyID)
        sealed = try container.decode(ATBytes.self, forKey: .sealed).data
        chunks = try container.decodeIfPresent([BlobRef].self, forKey: .chunks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.node, forKey: .type)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(ATBytes(sealed), forKey: .sealed)
        try container.encodeIfPresent(chunks, forKey: .chunks)
    }

    /// The sealed fields: all of `NodeRecord`, with the chunks as CIDs.
    struct Payload: Codable {
        var name: String
        var parent: String?
        var kind: NodeRecord.Kind
        var size: Int?
        var sha256: String?
        var chunks: [String]?
        var createdAt: String
        var modifiedAt: String?
    }

    init(_ record: NodeRecord, key: DriveKey, context: String) {
        let payload = Payload(
            name: record.name, parent: record.parent, kind: record.kind, size: record.size,
            sha256: record.sha256, chunks: record.chunks?.map(\.cid), createdAt: record.createdAt,
            modifiedAt: record.modifiedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        self.init(
            keyID: key.id, sealed: key.seal(try! encoder.encode(payload), context: context), chunks: record.chunks)
    }

    func open(with key: DriveKey, context: String) throws -> NodeRecord {
        guard keyID == key.id else {
            throw ATDriveError.encryption("encrypted with a different key than this device's")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: try key.open(sealed, context: context))
        guard payload.chunks ?? [] == (chunks ?? []).map(\.cid) else {
            throw ATDriveError.encryption("its chunks don't match its sealed list")
        }
        var record = NodeRecord(
            name: payload.name, parent: payload.parent, kind: payload.kind, size: payload.size,
            sha256: payload.sha256, chunks: chunks)
        record.createdAt = payload.createdAt
        record.modifiedAt = payload.modifiedAt
        return record
    }
}

/// A node record as listed: sealed, or plaintext from before drives were encrypted (`Drive`
/// encrypts those when you sign in; see `Drive.encryptOlderItems`).
enum StoredNode: Decodable, Sendable {
    case sealed(SealedNode)
    case plaintext(NodeRecord)

    init(from decoder: Decoder) throws {
        if let sealed = try? SealedNode(from: decoder) {
            self = .sealed(sealed)
        } else {
            self = .plaintext(try NodeRecord(from: decoder))
        }
    }
}

/// The drive key, wrapped for one passkey: the `me.jsnelgro.atdrive.key` record.
///
/// The wrapping key comes from the passkey's PRF output (see `DriveUnlock`), which only the
/// passkey can produce, so the PDS stores this without being able to open it.
struct KeyRecord: Codable, Sendable {
    static let passkey = "passkey"

    /// How it's wrapped. Only "passkey" so far.
    var kind: String
    /// The passkey's credential ID, base64url.
    var credentialID: String
    /// `DriveKey.id` of the key inside.
    var keyID: String
    var wrapped: Data
    var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case kind, credentialID, keyID, wrapped, createdAt
    }

    init(kind: String, credentialID: String, keyID: String, wrapped: Data, createdAt: Date = Date()) {
        self.kind = kind
        self.credentialID = credentialID
        self.keyID = keyID
        self.wrapped = wrapped
        self.createdAt = Timestamp.format(createdAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        credentialID = try container.decode(String.self, forKey: .credentialID)
        keyID = try container.decode(String.self, forKey: .keyID)
        wrapped = try container.decode(ATBytes.self, forKey: .wrapped).data
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.key, forKey: .type)
        try container.encode(kind, forKey: .kind)
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(ATBytes(wrapped), forKey: .wrapped)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// atproto `bytes` in JSON: `{"$bytes": "<base64, no padding>"}`.
struct ATBytes: Codable {
    var data: Data
    init(_ data: Data) { self.data = data }

    private enum CodingKeys: String, CodingKey { case bytes = "$bytes" }

    init(from decoder: Decoder) throws {
        var base64 = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .bytes)
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad $bytes"))
        }
        self.data = data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data.base64EncodedString().replacingOccurrences(of: "=", with: ""), forKey: .bytes)
    }
}

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

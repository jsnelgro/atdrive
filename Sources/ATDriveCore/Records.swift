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
///
/// It's the node's current state. Every change to it also writes a `VersionRecord` (its
/// history), and it names the latest one (`version`).
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
    /// Record key of the node's current version (`VersionRecord`): the change that left it like
    /// this. `nil` for records written before there was history.
    public var version: String?
    /// Files only: the version that holds these `chunks` in history. A rename or move points
    /// its version there rather than copying the chunk list.
    public var contentsFrom: String?

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
        case name, parent, kind, size, sha256, chunks, createdAt, modifiedAt, version, contentsFrom
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
        version = try container.decodeIfPresent(String.self, forKey: .version)
        contentsFrom = try container.decodeIfPresent(String.self, forKey: .contentsFrom)
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
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(contentsFrom, forKey: .contentsFrom)
    }

    public var modifiedDate: Date? { modifiedAt.flatMap(Timestamp.parse) }
    public var createdDate: Date? { Timestamp.parse(createdAt) }

    /// Whether two records describe the same thing in the same place (name, folder, kind and
    /// contents), whichever versions they came from.
    func sameState(as other: NodeRecord) -> Bool {
        name == other.name && parent == other.parent && kind == other.kind && sha256 == other.sha256
            && size == other.size
    }
}

/// One change to a file or folder: the `me.jsnelgro.atdrive.version` record. Its record key is a
/// TID made when the change was, so it also says when (`TID.date`).
///
/// It holds the node's state after the change (none after a delete), so the drive as it was at
/// any time can be put together again, and `prev`, the version the change was based on. Two
/// versions with the same `prev` are a race; `DriveHistory` finds the one that lost.
///
/// `chunks` is a field of its own, apart from the rest, because the server has to see blob refs
/// to keep the blobs alive: everything else can later be sealed.
public struct VersionRecord: Codable, Sendable, Equatable {
    public enum Change: String, Codable, Sendable {
        case created, edited, moved, deleted, restored
    }

    /// Record key of the node (file or folder) that changed.
    public var node: String
    public var change: Change
    /// The device that made the change (`DeviceName`).
    public var device: String
    /// Record key of the version this change was based on: the node's current version as the
    /// device last saw it. `nil` for a node's first version.
    public var prev: String?

    // The node's state after the change: all `nil` after a delete.
    public var name: String?
    public var parent: String?
    public var kind: NodeRecord.Kind?
    public var size: Int?
    public var sha256: String?
    public var createdAt: String?
    public var modifiedAt: String?
    /// Files: the version that holds this state's chunks, when this one doesn't (a rename or
    /// move, or a restore). It always names a version with `chunks`, never another pointer.
    public var contentsFrom: String?
    /// Files: the contents, when this version holds them itself.
    public var chunks: [BlobRef]?

    /// A version recording `state` (`nil` for a delete). `holdsContents` puts the chunk list in
    /// it; otherwise it points to the version that has them, `state.contentsFrom`.
    public init(
        node: String, change: Change, device: String, prev: String?, state: NodeRecord?, holdsContents: Bool
    ) {
        self.node = node
        self.change = change
        self.device = device
        self.prev = prev
        guard let state else { return }
        name = state.name
        parent = state.parent
        kind = state.kind
        size = state.size
        sha256 = state.sha256
        createdAt = state.createdAt
        modifiedAt = state.modifiedAt
        if state.kind == .file {
            if holdsContents || state.contentsFrom == nil {
                chunks = state.chunks ?? []
            } else {
                contentsFrom = state.contentsFrom
            }
        }
    }

    public var isDeletion: Bool { change == .deleted }

    /// The node as this version left it, without `chunks` if they're in another version
    /// (`contentsFrom`). `nil` for a delete.
    public var state: NodeRecord? {
        guard !isDeletion, let name, let kind else { return nil }
        var record = NodeRecord(name: name, parent: parent, kind: kind, size: size, sha256: sha256, chunks: chunks)
        record.createdAt = createdAt ?? record.createdAt
        record.modifiedAt = modifiedAt
        return record
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case node, change, device, prev, name, parent, kind, size, sha256, createdAt, modifiedAt, contentsFrom
        case chunks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(String.self, forKey: .node)
        change = try container.decode(Change.self, forKey: .change)
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? ""
        prev = try container.decodeIfPresent(String.self, forKey: .prev)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        kind = try container.decodeIfPresent(NodeRecord.Kind.self, forKey: .kind)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(String.self, forKey: .modifiedAt)
        contentsFrom = try container.decodeIfPresent(String.self, forKey: .contentsFrom)
        chunks = try container.decodeIfPresent([BlobRef].self, forKey: .chunks)
        // A change other than a delete always says what the node became.
        if change != .deleted, name == nil || kind == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "a \(change) version without a state")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.version, forKey: .type)
        try container.encode(node, forKey: .node)
        try container.encode(change, forKey: .change)
        try container.encode(device, forKey: .device)
        try container.encodeIfPresent(prev, forKey: .prev)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(contentsFrom, forKey: .contentsFrom)
        try container.encodeIfPresent(chunks, forKey: .chunks)
    }
}

/// The drive's settings, which every device follows: the `me.jsnelgro.atdrive.settings` record,
/// key `self`. Written once, when the drive is created.
public struct DriveSettings: Codable, Sendable, Equatable {
    public static let defaultRetentionDays = 30

    /// How long history is kept (versions, and the trash).
    public var retentionDays: Int
    /// Random, made when the drive is created. A drive with another ID was wiped and created
    /// again, even if it's in the same place: what a device synced before isn't in it.
    public var driveID: String?

    public init(retentionDays: Int = defaultRetentionDays, driveID: String? = DriveSettings.newDriveID()) {
        self.retentionDays = retentionDays
        self.driveID = driveID
    }

    public var retention: TimeInterval { Double(max(retentionDays, 1)) * 24 * 60 * 60 }

    /// 128 random bits, as hex.
    public static func newDriveID() -> String {
        (0..<16).map { _ in UInt8.random(in: 0...255) }.hexString
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case retentionDays, driveID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? Self.defaultRetentionDays
        driveID = try container.decodeIfPresent(String.self, forKey: .driveID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.settings, forKey: .type)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encodeIfPresent(driveID, forKey: .driveID)
    }
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

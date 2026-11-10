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

/// One chunk of a file: the blob holding its ciphertext, and the ID that decrypts it
/// (`DriveKey.encryptChunk`). In a stored record the two are apart: the blob refs stay readable,
/// so the PDS keeps the blobs, and the IDs are sealed, in the same order.
public struct ChunkRef: Codable, Sendable, Hashable {
    public var blob: BlobRef
    public var id: ChunkID

    public init(blob: BlobRef, id: ChunkID) {
        self.blob = blob
        self.id = id
    }

    /// The blob's CID: of the ciphertext.
    public var cid: String { blob.cid }
    /// The chunk's contents' size. The blob stored is 16 bytes longer: AES-GCM's tag.
    public var size: Int { max(blob.size - Self.overhead, 0) }

    static let overhead = 16
}

/// One file or folder in a drive: the `me.jsnelgro.atdrive.node` record, as it reads once
/// unsealed. Stored, all of it but the chunks' blob refs is sealed (`SealedRecord`).
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
    /// Files only: the content, in order. Decrypted and concatenated, they are the file.
    public var chunks: [ChunkRef]?
    public var createdAt: String
    /// Files only: the file's own modification time, restored on download.
    public var modifiedAt: String?
    /// Record key of the node's current version (`VersionRecord`): the change that left it like
    /// this.
    public var version: String?
    /// Files only: the version that holds these `chunks` in history. A rename or move points
    /// its version there rather than copying the chunk list.
    public var contentsFrom: String?
    /// Files only: how many `me.jsnelgro.atdrive.chunks` records hold `chunks`, when the list is
    /// too long for a record. They're the ones of the version `contentsFrom`, and then neither
    /// that version nor this record holds the chunks itself. `nil`: the list is in the record.
    public var continuations: Int?

    public init(
        name: String, parent: String?, kind: Kind, size: Int? = nil, sha256: String? = nil,
        chunks: [ChunkRef]? = nil, createdAt: Date = Date(), modifiedAt: Date? = nil
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

    public var modifiedDate: Date? { modifiedAt.flatMap(Timestamp.parse) }
    public var createdDate: Date? { Timestamp.parse(createdAt) }
}

/// One change to a file or folder: the `me.jsnelgro.atdrive.version` record, as it reads once
/// unsealed. Its record key is a TID made when the change was, so it also says when
/// (`TID.date`).
///
/// It holds the node's state after the change (none after a delete), so the drive as it was at
/// any time can be put together again, and `prev`, the version the change was based on. Two
/// versions with the same `prev` are a race; `DriveHistory` finds the one that lost.
///
/// Stored, all of it but the chunks' blob refs is sealed (`SealedRecord`): the server has to see
/// blob refs to keep the blobs alive, and nothing else.
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
    public var chunks: [ChunkRef]?
    /// Files: how many `me.jsnelgro.atdrive.chunks` records hold `chunks`, when the list is too
    /// long for this record (see `NodeRecord.continuations`). Their keys start with this
    /// version's (`Lexicon.continuationKey`), and they go when it does.
    public var continuations: Int?

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
                continuations = state.continuations
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
        record.continuations = continuations
        return record
    }
}

/// The drive's settings, which every device follows: the `me.jsnelgro.atdrive.settings` record,
/// key `self`, as it reads once unsealed. Written when the drive is created, and when a device
/// is approved or removed (`roster`).
///
/// It's sealed like the rest, so the PDS can't change it: with a readable retention, it could set
/// it to a day and have every device prune the history.
public struct DriveSettings: Codable, Sendable, Equatable {
    public static let defaultRetentionDays = 30

    /// How long history is kept (versions, and the trash).
    public var retentionDays: Int
    /// Random, made when the drive is created. A drive with another ID was wiped and created
    /// again, even if it's in the same place: what a device synced before isn't in it.
    public var driveID: String?
    /// The devices approved to hold the drive's key. Their public keys are the ones keyrings are
    /// wrapped for, and the senders a device accepts a keyring from (see `KeyTrust`): unlike a
    /// device record, the PDS can't change these.
    public var roster: [RosterEntry]

    public init(
        retentionDays: Int = defaultRetentionDays, driveID: String? = DriveSettings.newDriveID(),
        roster: [RosterEntry] = []
    ) {
        self.retentionDays = retentionDays
        self.driveID = driveID
        self.roster = roster
    }

    public var retention: TimeInterval { Double(max(retentionDays, 1)) * 24 * 60 * 60 }

    /// 128 random bits, as hex.
    public static func newDriveID() -> String {
        (0..<16).map { _ in UInt8.random(in: 0...255) }.hexString
    }

    private enum CodingKeys: String, CodingKey {
        case retentionDays, driveID, roster
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? Self.defaultRetentionDays
        driveID = try container.decodeIfPresent(String.self, forKey: .driveID)
        roster = try container.decodeIfPresent([RosterEntry].self, forKey: .roster) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encodeIfPresent(driveID, forKey: .driveID)
        try container.encode(roster, forKey: .roster)
    }

    /// The roster entry for a public key.
    public func member(_ publicKey: Data) -> RosterEntry? {
        roster.first { $0.publicKey.data == publicKey }
    }
}

/// A device approved to hold the drive's key, as the drive's sealed settings list it.
public struct RosterEntry: Codable, Sendable, Equatable {
    /// The device's ID: the key of its device record.
    public var id: String
    public var name: String
    /// Its raw Curve25519 public key.
    public var publicKey: Bytes

    public init(id: String, name: String, publicKey: Bytes) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
    }
}

/// A device that holds the drive's key, or asks for it: the `me.jsnelgro.atdrive.device`
/// record, keyed by the device's ID.
///
/// It isn't sealed. A device asks for the key before it has one, and the others read its public
/// key to wrap the keyring for it. What it holds is public, or wrapped already. The PDS can
/// change it, so nothing here is trusted on its own: keyrings are wrapped for the public keys
/// in the sealed roster, and a pairing code is compared before a new one is added.
public struct DeviceRecord: Codable, Sendable, Equatable {
    public var name: String
    /// The device's raw Curve25519 public key.
    public var publicKey: Bytes
    /// The drive's keyring, wrapped for this device. `nil` while it waits to be approved.
    public var keyring: WrappedKeyring?
    /// The device that approved this one (wrapped its first keyring), if it wasn't itself.
    public var approvedBy: String?
    public var createdAt: String

    public init(
        name: String, publicKey: Bytes, keyring: WrappedKeyring? = nil, approvedBy: String? = nil,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.publicKey = publicKey
        self.keyring = keyring
        self.approvedBy = approvedBy
        self.createdAt = Timestamp.format(createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case name, publicKey, keyring, approvedBy, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        publicKey = try container.decode(Bytes.self, forKey: .publicKey)
        keyring = try container.decodeIfPresent(WrappedKeyring.self, forKey: .keyring)
        approvedBy = try container.decodeIfPresent(String.self, forKey: .approvedBy)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.device, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encodeIfPresent(keyring, forKey: .keyring)
        try container.encodeIfPresent(approvedBy, forKey: .approvedBy)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// The drive's keyring wrapped with the recovery key: the device collection's record with key
/// `recovery`. Only someone with the recovery key can make one, so it's trusted as it is.
public struct RecoveryRecord: Codable, Sendable, Equatable {
    public var keyring: RecoveryWrappedKeyring

    public init(keyring: RecoveryWrappedKeyring) {
        self.keyring = keyring
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case keyring = "recoveryKeyring"
    }

    public init(from decoder: Decoder) throws {
        keyring = try decoder.container(keyedBy: CodingKeys.self).decode(
            RecoveryWrappedKeyring.self, forKey: .keyring)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.device, forKey: .type)
        try container.encode(keyring, forKey: .keyring)
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

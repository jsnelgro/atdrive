import Crypto
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

/// One chunk of a file: the blob holding it, and, if it's encrypted, the ID that decrypts it
/// (`DriveKey.encryptChunk`) and the key that ID was made with.
///
/// A plain chunk is the file's bytes as they are, and its blob's CID names it. An encrypted
/// chunk's blob is ciphertext. In a stored record the blob refs always stay readable, so the PDS
/// keeps the blobs; the IDs sit beside them in a plain record, or sealed in a sealed one, in the
/// same order.
public struct ChunkRef: Codable, Sendable, Hashable {
    public var blob: BlobRef
    /// `nil` for a plain chunk.
    public var id: ChunkID?
    /// Encrypted chunks: the drive key the ID was made with (the keyring's first key when it was
    /// stored). It says whether the chunk still belongs to the drive's current keys, or is left
    /// from before encryption was turned off and on again (`Drive.convert`).
    public var key: KeyID?

    public init(blob: BlobRef, id: ChunkID? = nil, key: KeyID? = nil) {
        self.blob = blob
        self.id = id
        self.key = id == nil ? nil : key
    }

    /// The blob's CID: of the bytes as stored (the ciphertext, if encrypted).
    public var cid: String { blob.cid }
    /// The chunk's contents' size. An encrypted chunk's blob is 16 bytes longer: AES-GCM's tag.
    public var size: Int { isEncrypted ? max(blob.size - Self.overhead, 0) : blob.size }
    public var isEncrypted: Bool { id != nil }

    static let overhead = 16
}

/// One file or folder in a drive: the `app.atdrive.node` record, as it reads whether
/// it's stored plain or sealed (`StoredRecords.swift`).
///
/// Files and folders reference their parent by ID rather than storing a path, so renaming or
/// moving anything (even a folder with thousands of files inside) is a single record update.
/// File contents are split into chunks, each stored as a blob, listed in order.
///
/// It's the node's current state. Every change to it also writes a `VersionRecord` (its
/// history), and it names the latest one (`version`).
public struct NodeRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// `mount`: where another space (a shared folder) appears in the drive. It holds no
        /// children of its own here: they're that space's (`mount`).
        case file, folder, mount
    }

    public var name: String
    /// Record key of the parent folder; `nil` means the top level of the drive.
    public var parent: String?
    public var kind: Kind
    /// Files only: total size in bytes.
    public var size: Int?
    /// Files only: hex SHA-256 of the whole file, checked after every download.
    public var sha256: String?
    /// Files only: the content, in order. Decrypted (if encrypted) and concatenated, they are
    /// the file.
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
    /// Files only: how many `app.atdrive.chunks` records hold `chunks`, when the list is
    /// too long for a record. They're the ones of the version `contentsFrom`, and then neither
    /// that version nor this record holds the chunks itself. `nil`: the list is in the record.
    public var continuations: Int?
    /// The number of the first of those records, when it isn't 1 (see
    /// `VersionRecord.continuationsFrom`).
    public var continuationsFrom: Int?
    /// Mounts only: the space that appears here.
    public var mount: MountInfo?

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

/// One change to a file or folder: the `app.atdrive.version` record, as it reads whether
/// it's stored plain or sealed. Its record key is a TID made when the change was, so it also says when
/// (`TID.date`).
///
/// It holds the node's state after the change (none after a delete), so the drive as it was at
/// any time can be put together again, and `prev`, the version the change was based on. Two
/// versions with the same `prev` are a race; `DriveHistory` finds the one that lost.
///
/// Sealed, all of it but the chunks' blob refs is encrypted: the server has to see blob refs to
/// keep the blobs alive, and nothing else.
public struct VersionRecord: Codable, Sendable, Equatable {
    public enum Change: String, Codable, Sendable {
        /// `shared`: deleted from this space because it moved into a space of its own, to be
        /// shared (`Sharing.share`). It isn't in the trash: it's still in the drive, in the mount.
        case created, edited, moved, deleted, restored, shared
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
    /// Files: how many `app.atdrive.chunks` records hold `chunks`, when the list is too
    /// long for this record (see `NodeRecord.continuations`). Their keys start with this
    /// version's (`Lexicon.continuationKey`), and they go when it does.
    public var continuations: Int?
    /// The number of the first of those records, when it isn't 1. Rewriting a long chunk list
    /// (`Drive.convert`) writes the new records after the old ones, then switches the version to
    /// them in one write, so the list is whole at every moment.
    public var continuationsFrom: Int?
    /// Mounts: the space that appeared there.
    public var mount: MountInfo?

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
        mount = state.mount
        if state.kind == .file {
            if holdsContents || state.contentsFrom == nil {
                chunks = state.chunks ?? []
                continuations = state.continuations
                continuationsFrom = state.continuationsFrom
            } else {
                contentsFrom = state.contentsFrom
            }
        }
    }

    public var isDeletion: Bool { change == .deleted || change == .shared }

    /// The node as this version left it, without `chunks` if they're in another version
    /// (`contentsFrom`). `nil` for a delete.
    public var state: NodeRecord? {
        guard !isDeletion, let name, let kind else { return nil }
        var record = NodeRecord(name: name, parent: parent, kind: kind, size: size, sha256: sha256, chunks: chunks)
        record.createdAt = createdAt ?? record.createdAt
        record.modifiedAt = modifiedAt
        record.continuations = continuations
        record.continuationsFrom = continuationsFrom
        record.mount = mount
        return record
    }
}

/// Where a space appears in a drive: what a mount node holds (`NodeRecord.mount`).
///
/// It's how the drive keeps the spaces in it: its owner's shared folders, and other people's
/// opened from a link. Being a node, a mount can be renamed, moved and deleted like a folder, and
/// has history. Deleting one never deletes the space.
public struct MountInfo: Codable, Sendable, Equatable {
    /// The space's address: `at://<authority>/space/<type>/<key>`.
    public var space: String
    /// An encrypted space the drive's owner shared: its keyring (raw keys, oldest first), for
    /// every one of the owner's devices. Only ever stored sealed, in an encrypted drive: a plain
    /// drive refuses to write it (see `Drive.stored`).
    public var keyring: [Bytes]?
    /// Someone else's encrypted share opened from its link: the link's key, which opens the
    /// keyring in the share's link record. Readable on a plain drive, as its owner was told.
    public var linkKey: Bytes?
    /// Whether the space was encrypted when it was mounted. A space that was can't become plain:
    /// its settings saying so would be the PDS's doing, and writing there in the clear would leak.
    public var encrypted: Bool?

    public init(space: String, keyring: Keyring? = nil, linkKey: Data? = nil, encrypted: Bool? = nil) {
        self.space = space
        self.keyring = keyring.map { $0.keys.map { Bytes($0.rawRepresentation) } }
        self.linkKey = linkKey.map(Bytes.init)
        self.encrypted = encrypted ?? (keyring != nil || linkKey != nil ? true : nil)
    }

    /// Whether it must be encrypted: it was, or it holds keys for it.
    var mustBeEncrypted: Bool { encrypted == true || keyring != nil || linkKey != nil }

    /// Its keyring replaced (keeping everything else, the link key included).
    func with(_ keyring: Keyring) -> MountInfo {
        var copy = self
        copy.keyring = keyring.keys.map { Bytes($0.rawRepresentation) }
        copy.encrypted = true
        return copy
    }

    /// The space's owner.
    public var owner: String { XRPCClient.spaceParts(space)?.authority ?? "" }

    /// The keyring, if it holds one.
    public var spaceKeyring: Keyring? {
        guard let keyring, !keyring.isEmpty else { return nil }
        return try? Keyring(keyring.map { try DriveKey(rawRepresentation: $0.data) })
    }
}

/// The drive's settings, which every device follows: the `app.atdrive.settings` record,
/// key `self`. Written when the drive is created, and whenever encryption is turned on or off.
///
/// How it's stored says whether the drive is encrypted: sealed on an encrypted drive, plain on
/// one that isn't (`Drive.mode`). Sealed, the PDS can't change it: with a readable retention, it
/// could set it to a day and have every device prune the history. On a plain drive the PDS is
/// trusted with everything anyway.
public struct DriveSettings: Codable, Sendable, Equatable {
    public static let defaultRetentionDays = 30
    /// The shortest retention taken from a plain settings record when encryption is turned on
    /// (`Drive.settingsToSeal`): the PDS could have written a shorter one.
    public static let minimumUntypedRetentionDays = 7

    /// How long history is kept (versions, and the trash).
    public var retentionDays: Int
    /// Random, made when the drive is created. A drive with another ID was wiped and created
    /// again, even if it's in the same place: what a device synced before isn't in it. Turning
    /// encryption on or off keeps it.
    public var driveID: String?
    /// Encrypted drives: records that aren't sealed with the drive's keys are still read. That's
    /// so while what was there before encryption was turned on is being encrypted
    /// (`Drive.convert`), and it ends when that's done: from then on, such a record is one the
    /// PDS could have made, and is ignored.
    public var converting: Bool
    /// Keys the drive no longer seals with, while what's sealed with them is still read:
    ///
    /// - On a plain drive, its keys from when it was last encrypted, published when encryption
    ///   was turned off, so everything sealed with them stays readable. They're no secret any
    ///   more. Holding them also proves the drive's own devices turned encryption off, not the PDS
    ///   (`Drive.open`).
    /// - On an encrypted drive, while it's `converting` or `rotating`: the keys it had before, so
    ///   what's still sealed with them reads until `Drive.convert` has sealed it again. Then
    ///   they're dropped, and only remembered in `formerKeys`.
    public var retiredKeys: [Bytes]
    /// Encrypted drives: its keys were replaced (`Drive.rotateKeys`, or removing a device), and
    /// what's sealed with the old ones (`retiredKeys`) is still read while `Drive.convert` seals
    /// it again with the new key. Unlike `converting`, records that aren't sealed at all aren't.
    public var rotating: Bool
    /// Encrypted drives: keys the drive used to have and that nothing is sealed with any more,
    /// by ID and fingerprint, never the keys themselves. A record sealed with one is refused
    /// (`UnreadableNode.Reason.formerKey`), and a device that knew one takes a keyring without
    /// it (`KeyTrust`).
    public var formerKeys: [FormerKey]
    /// Counts the changes to these settings. On an encrypted drive, a device refuses settings
    /// older than ones it has read (`DeviceTrust.settingsGeneration`): the PDS can't forge sealed
    /// settings, but it could serve an old copy, say one from while `converting` was on.
    public var generation: Int
    /// The account's sharing key (raw X25519 private key), home drives only: sealed with the rest
    /// on an encrypted drive, readable on a plain one (`SharingKeyPair`). Replaced whenever
    /// encryption is turned on or off.
    public var sharingKey: Bytes?
    /// Shares only: the shared file's or folder's name, for those who open it.
    public var name: String?
    /// Shares only: it's one file (the space holds just that file), shown as the file rather than
    /// a folder (`JoinedSnapshot.join`).
    public var file: Bool

    public init(
        retentionDays: Int = defaultRetentionDays, driveID: String? = DriveSettings.newDriveID(),
        converting: Bool = false, retiredKeys: [Bytes] = [], rotating: Bool = false, formerKeys: [FormerKey] = [],
        generation: Int = 0, sharingKey: Bytes? = nil, name: String? = nil, file: Bool = false
    ) {
        self.sharingKey = sharingKey
        self.name = name
        self.file = file
        self.retentionDays = retentionDays
        self.driveID = driveID
        self.generation = generation
        self.converting = converting
        self.retiredKeys = retiredKeys
        self.rotating = rotating
        self.formerKeys = formerKeys
    }

    public var retention: TimeInterval { Double(max(retentionDays, 1)) * 24 * 60 * 60 }

    /// 128 random bits, as hex.
    public static func newDriveID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }.hexString
    }

    /// The retired keys as a keyring, oldest first; `nil` if there are none, or they aren't keys.
    public var retiredKeyring: Keyring? {
        guard !retiredKeys.isEmpty else { return nil }
        return try? Keyring(retiredKeys.map { try DriveKey(rawRepresentation: $0.data) })
    }

    private enum CodingKeys: String, CodingKey {
        case retentionDays, driveID, converting, retiredKeys, rotating, formerKeys, generation, sharingKey, name, file
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? Self.defaultRetentionDays
        driveID = try container.decodeIfPresent(String.self, forKey: .driveID)
        converting = try container.decodeIfPresent(Bool.self, forKey: .converting) ?? false
        retiredKeys = try container.decodeIfPresent([Bytes].self, forKey: .retiredKeys) ?? []
        rotating = try container.decodeIfPresent(Bool.self, forKey: .rotating) ?? false
        formerKeys = try container.decodeIfPresent([FormerKey].self, forKey: .formerKeys) ?? []
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        sharingKey = try container.decodeIfPresent(Bytes.self, forKey: .sharingKey)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        file = try container.decodeIfPresent(Bool.self, forKey: .file) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encodeIfPresent(driveID, forKey: .driveID)
        if converting { try container.encode(converting, forKey: .converting) }
        if !retiredKeys.isEmpty { try container.encode(retiredKeys, forKey: .retiredKeys) }
        if rotating { try container.encode(rotating, forKey: .rotating) }
        if !formerKeys.isEmpty { try container.encode(formerKeys, forKey: .formerKeys) }
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(sharingKey, forKey: .sharingKey)
        try container.encodeIfPresent(name, forKey: .name)
        if file { try container.encode(file, forKey: .file) }
    }

    /// Every key these settings name as having been the drive's, retired or former, by
    /// fingerprint (`DriveKey.fingerprint`).
    var pastKeyFingerprints: Set<String> {
        Set((retiredKeyring?.keys.map(\.fingerprint) ?? []) + formerKeys.map(\.fingerprint))
    }

    /// The retired keys become former ones: nothing is sealed with them any more.
    mutating func forgetRetiredKeys() {
        for key in retiredKeyring?.keys ?? [] where !formerKeys.contains(where: { $0.id == key.id }) {
            formerKeys.append(FormerKey(key))
        }
        retiredKeys = []
    }

    /// The sharing key pair, if there is one. `encrypted`: whether these settings are stored sealed.
    public func sharingKeyPair(encrypted: Bool) -> SharingKeyPair? {
        guard let sharingKey, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: sharingKey.data)
        else { return nil }
        return SharingKeyPair(privateKey: key, protected: encrypted)
    }
}

/// A key a drive used to have (`DriveSettings.formerKeys`): its ID, which records sealed with it
/// carry, and its fingerprint, which devices that accepted it remember. Neither opens anything.
public struct FormerKey: Codable, Sendable, Equatable {
    public var id: KeyID
    public var fingerprint: String

    public init(_ key: DriveKey) {
        id = key.id
        fingerprint = key.fingerprint
    }
}

/// A device approved to hold the drive's keys: what its device record's `member` seals, with
/// the drive's current key, so only a device that holds the keys can add one, and the PDS can't
/// change it or bring back an old one (`Drive.roster`).
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

/// A device that holds the drive's key, or asks for it: the `app.atdrive.device`
/// record, keyed by the device's ID.
///
/// It isn't sealed as a whole. A device asks for the key before it has one, and the others read
/// its public key to wrap the keyring for it. What it holds is public, or wrapped already. The
/// PDS can change it, so nothing here is trusted on its own, but for `member`: keyrings are
/// wrapped only for devices whose `member` opens, and a pairing code is compared before one is
/// added.
///
/// One record per device, each written only when that device is approved, or when the keys
/// change (which rewrites them all), so two devices approving different devices at the same
/// moment don't overwrite each other.
public struct DeviceRecord: Codable, Sendable, Equatable {
    public var name: String
    /// The device's raw Curve25519 public key.
    public var publicKey: Bytes
    /// The drive's keyring, wrapped for this device. `nil` while it waits to be approved.
    public var keyring: WrappedKeyring?
    /// The device that approved this one (wrapped its first keyring), if it wasn't itself.
    public var approvedBy: String?
    /// That this device is approved: its `RosterEntry`, sealed with the drive's current key for
    /// this record. `nil` while it waits.
    public var member: SealedValue?
    public var createdAt: String

    public init(
        name: String, publicKey: Bytes, keyring: WrappedKeyring? = nil, approvedBy: String? = nil,
        member: SealedValue? = nil, createdAt: Date = Date()
    ) {
        self.name = name
        self.publicKey = publicKey
        self.keyring = keyring
        self.approvedBy = approvedBy
        self.member = member
        self.createdAt = Timestamp.format(createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case name, publicKey, keyring, approvedBy, member, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        publicKey = try container.decode(Bytes.self, forKey: .publicKey)
        keyring = try container.decodeIfPresent(WrappedKeyring.self, forKey: .keyring)
        approvedBy = try container.decodeIfPresent(String.self, forKey: .approvedBy)
        member = try container.decodeIfPresent(SealedValue.self, forKey: .member)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.device, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encodeIfPresent(keyring, forKey: .keyring)
        try container.encodeIfPresent(approvedBy, forKey: .approvedBy)
        try container.encodeIfPresent(member, forKey: .member)
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

import Crypto
import Foundation

// Keys for encrypted shares (PLAN.md, "Sharing → Keys for encrypted shares"). A shared space's
// keyring reaches:
// - the owner's devices through the mount (`MountInfo.keyring`), sealed in the encrypted home drive;
// - members through their member record: the keyring wrapped for their sharing key;
// - anyone with the link through the link record: the keyring sealed with the link's key, which
//   travels in the link's `#fragment` and never reaches a server.

/// An account's sharing key: an X25519 key pair. The private key is in the home drive's settings
/// (`DriveSettings.sharingKey`): sealed on an encrypted drive, readable on a plain one
/// (`protected` says which). The public key is published in the account's public repo
/// (`SharingKeyRecord`), for owners to wrap keyrings for.
public struct SharingKeyPair: Sendable, Equatable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let protected: Bool

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), protected: Bool) {
        self.privateKey = privateKey
        self.protected = protected
    }

    public var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    public static func == (a: SharingKeyPair, b: SharingKeyPair) -> Bool {
        a.privateKey.rawRepresentation == b.privateKey.rawRepresentation && a.protected == b.protected
    }
}

/// The public half, as published: `me.jsnelgro.atdrive.shareKey`, rkey `self`, in the account's
/// public repo.
public struct SharingKeyRecord: Codable, Sendable, Equatable {
    /// Raw X25519 public key.
    public var publicKey: Bytes
    /// Whether the private key is kept encrypted (an encrypted drive). If not, whoever runs the
    /// account's PDS can read what's shared with it.
    public var protected: Bool
    public var createdAt: String

    public init(publicKey: Curve25519.KeyAgreement.PublicKey, protected: Bool, createdAt: Date = Date()) {
        self.publicKey = Bytes(publicKey.rawRepresentation)
        self.protected = protected
        self.createdAt = Timestamp.format(createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case publicKey, protected, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicKey = try container.decode(Bytes.self, forKey: .publicKey)
        protected = try container.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.shareKey, forKey: .type)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(protected, forKey: .protected)
        try container.encode(createdAt, forKey: .createdAt)
    }

    public var key: Curve25519.KeyAgreement.PublicKey? {
        try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey.data)
    }

    /// A short fingerprint to compare and remember: the first 16 bytes of its SHA-256, in groups.
    public var fingerprint: String { SharingKeyRecord.fingerprint(of: publicKey.data) }

    public static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(16).hexString
        return stride(from: 0, to: hex.count, by: 4).map {
            String(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 4)])
        }.joined(separator: " ")
    }

    /// An account's published sharing key, read from its PDS (signed out: it's public); `nil` if
    /// it hasn't published one.
    public static func fetch(_ did: String, resolver: IdentityResolver, transport: any HTTPTransport) async throws
        -> SharingKeyRecord?
    {
        let pds = try await resolver.resolve(did).pds
        let client = XRPCClient(service: pds, transport: transport)
        guard
            let value = try await client.getPublicRecord(
                repo: did, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey)
        else { return nil }
        return try? value.decode(as: SharingKeyRecord.self)
    }
}

/// A member's record in an encrypted share: `me.jsnelgro.atdrive.member`, rkey = their DID. The
/// share's keyring wrapped for their sharing key, from the owner's (HPKE auth mode, as device
/// records), and their membership sealed with the share's current key: the PDS can't make one, or
/// bring back a removed member's.
public struct MemberRecord: Codable, Sendable, Equatable {
    public var keyring: WrappedKeyring
    /// `MemberEntry`, sealed with the share's current key for this record.
    public var membership: SealedValue
    public var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case keyring, membership, createdAt
    }

    public init(keyring: WrappedKeyring, membership: SealedValue, createdAt: Date = Date()) {
        self.keyring = keyring
        self.membership = membership
        self.createdAt = Timestamp.format(createdAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyring = try container.decode(WrappedKeyring.self, forKey: .keyring)
        membership = try container.decode(SealedValue.self, forKey: .membership)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.member, forKey: .type)
        try container.encode(keyring, forKey: .keyring)
        try container.encode(membership, forKey: .membership)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// What a member record's `membership` seals.
public struct MemberEntry: Codable, Sendable, Equatable {
    public var did: String
    /// The sharing key the keyring was wrapped for.
    public var publicKey: Bytes
}

/// The link record of an encrypted share with a public link: `me.jsnelgro.atdrive.link`, rkey
/// `self`. The keyring, sealed (AES-256-GCM) with a key derived from the link key.
public enum ShareLink {
    /// A new link key: 256 random bits.
    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func wrappingKey(_ linkKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: linkKey), info: Data("atdrive link key v1".utf8), outputByteCount: 32)
    }

    /// The link record's value for `keyring`.
    static func record(for keyring: Keyring, linkKey: Data, space: String) throws -> JSONValue {
        let box = try AES.GCM.seal(
            keyring.rawRepresentation, using: wrappingKey(linkKey), authenticating: KeyWrapping.info(space: space))
        return .object([
            "$type": .string(Lexicon.link),
            "keyring": .object(["$bytes": .string(Base64.encode(box.combined!))]),
        ])
    }

    /// An encrypted share's keyring, from its link record and the link's key.
    static func keyring(space: String, owner: String, linkKey: Data, client: XRPCClient) async throws -> Keyring {
        let page = try await client.listRawSpaceRecords(space: space, repo: owner, collection: Lexicon.link)
        guard let value = page.records.first(where: { $0.rkey == Lexicon.linkKey })?.value,
            let text = value["keyring"]?["$bytes"]?.string, let sealed = Base64.decode(text)
        else { throw SharingError.linkKeyWrong }
        do {
            let raw = try AES.GCM.open(
                AES.GCM.SealedBox(combined: sealed), using: wrappingKey(linkKey),
                authenticating: KeyWrapping.info(space: space))
            return try Keyring(rawRepresentation: raw)
        } catch {
            throw SharingError.linkKeyWrong
        }
    }
}

/// Member records: how members get an encrypted share's keyring.
public enum MemberKeys {
    /// A member's record: `keyring` wrapped for `member`'s sharing key from the owner's, and the
    /// membership sealed with the keyring.
    static func record(
        keyring: Keyring, for member: String, key: Curve25519.KeyAgreement.PublicKey, from owner: SharingKeyPair,
        space: String
    ) throws -> JSONValue {
        let wrapped = try keyring.wrapped(for: key, from: owner.privateKey, space: space)
        let membership = try keyring.seal(
            MemberEntry(did: member, publicKey: Bytes(key.rawRepresentation)), space: space, collection: Lexicon.member,
            rkey: member)
        return try JSONValue(encoding: MemberRecord(keyring: wrapped, membership: membership))
    }

    /// The share's keyring from `me`'s member record. It's accepted only if it was wrapped by the
    /// sharing key the owner published, and the record's membership opens with it and names `me`.
    static func keyring(
        space: String, owner: String, me: String, keys: SharingKeyPair, client: XRPCClient, resolver: IdentityResolver?
    ) async throws -> Keyring {
        let page = try await client.listRawSpaceRecords(space: space, repo: owner, collection: Lexicon.member)
        guard let value = page.records.first(where: { $0.rkey == me })?.value,
            let record = try? value.decode(as: MemberRecord.self)
        else { throw MemberKeyProblem.noRecord }
        guard let resolver,
            let published = try await SharingKeyRecord.fetch(owner, resolver: resolver, transport: client.transport),
            published.publicKey == record.keyring.sender
        else { throw MemberKeyProblem.wrongSender }
        let keyring = try Keyring(unwrapping: record.keyring, with: keys.privateKey, space: space)
        guard
            let entry = try? keyring.open(
                record.membership, as: MemberEntry.self, space: space, collection: Lexicon.member, rkey: me),
            entry.did == me, entry.publicKey.data == keys.publicKey.rawRepresentation
        else { throw MemberKeyProblem.wrongSender }
        return keyring
    }

    public enum MemberKeyProblem: Error, CustomStringConvertible {
        case noRecord, wrongSender

        public var description: String {
            switch self {
            case .noRecord: "there are no keys for you in it (yet): ask its owner to add you again"
            case .wrongSender: "its keys for you weren't made by its owner's sharing key, so they aren't used"
            }
        }
    }
}

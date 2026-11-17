import Crypto
import Foundation

// Verification codes for sharing keys (#30). A sharing key is only as trustworthy as the PDS that
// publishes it: a malicious one could put in a key of its own, and receive the keyrings wrapped
// for it. Two people compare a code made from both their keys, over a channel they trust (in
// person, a call); each marks the other as verified, and the key is remembered in their home
// drive (sealed on an encrypted drive), for every one of their devices.

/// A person's sharing key, as verified: `me.jsnelgro.atdrive.contact`, rkey = their DID, in the
/// home drive.
public struct VerifiedKey: Codable, Sendable, Equatable {
    public var publicKey: Bytes
    public var verifiedAt: String

    public init(publicKey: Data, verifiedAt: Date = Date()) {
        self.publicKey = Bytes(publicKey)
        self.verifiedAt = Timestamp.format(verifiedAt)
    }
}

extension JoinedDrive {
    static let verificationLabel = "atdrive sharing key verification v1"

    /// The code to compare with `did`: 16 digits from both accounts' sharing keys, the same on
    /// both sides. Throws `noSharingKey` if they have none.
    public func verificationCode(with did: String) async throws -> (code: String, theirs: SharingKeyRecord) {
        let mine = try await ensureSharingKey()
        guard let resolver = access?.resolver,
            let theirs = try await SharingKeyRecord.fetch(did, resolver: resolver, transport: home.client.transport),
            let key = theirs.key
        else { throw SharingError.noSharingKey(did) }
        return (PairingCode.make(for: mine.publicKey, and: key, label: Self.verificationLabel), theirs)
    }

    /// Remembers `key` as `did`'s verified sharing key.
    public func markVerified(_ did: String, key: SharingKeyRecord) async throws {
        let value = try home.stored(VerifiedKey(publicKey: key.publicKey.data), collection: Lexicon.contact, rkey: did)
        let exists = try await verifiedKeys()[did] != nil
        try await home.apply([
            exists
                ? .update(collection: Lexicon.contact, rkey: did, value: value)
                : .create(collection: Lexicon.contact, rkey: did, value: value)
        ])
    }

    /// The sharing keys this account verified, by DID.
    public func verifiedKeys() async throws -> [String: Data] {
        let page = try await home.client.listRawSpaceRecords(
            space: home.space, repo: owner, collection: Lexicon.contact)
        var keys: [String: Data] = [:]
        for record in page.records {
            if let verified = home.read(
                record.value, as: VerifiedKey.self, collection: Lexicon.contact, rkey: record.rkey)
            {
                keys[record.rkey] = verified.publicKey.data
            }
        }
        return keys
    }

    /// Whether `did`'s published sharing key is the one this account verified.
    public func isVerified(_ did: String, key: SharingKeyRecord?) async throws -> Bool {
        guard let key else { return false }
        return try await verifiedKeys()[did] == key.publicKey.data
    }

    /// Gives this account a new sharing key, published at once: after removing a device (which
    /// may have had the old one). Owners of shares this account is in see a changed key, and wrap
    /// their keyrings for the new one once they've checked it.
    @discardableResult
    public func rotateSharingKey() async throws -> SharingKeyPair {
        _ = try await home.updateSettings { $0.sharingKey = nil }
        return try await ensureSharingKey()
    }
}

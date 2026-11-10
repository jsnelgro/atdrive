import Crypto
import Foundation

/// Names a drive key without revealing it: 8 bytes derived from the key, as 16 hex digits. Every
/// sealed record carries one, so readers know which key in their keyring opens it.
public struct KeyID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// The secret a drive is encrypted with: 32 random bytes, made when the drive is created. It's
/// stored only wrapped, for a device or for the recovery key (`Keyring.wrapped(for:)`).
///
/// It's never used directly. Each job gets its own subkey, derived with HKDF-SHA256 and a distinct
/// `info`, so a weakness in one use can't leak into another.
public struct DriveKey: Sendable, Equatable, CustomStringConvertible {
    /// What a derived value is for. Each case's raw value is its HKDF `info`. Add new purposes
    /// here, and never change or reuse a string: data sealed under it would become unreadable.
    /// (Swift rejects duplicate raw values, so two purposes can't share one by accident.)
    public enum Purpose: String, CaseIterable, Sendable {
        /// The key ID: public, so it's derived rather than hashed from the key directly.
        case keyID = "atdrive key id v1"
        /// AES-GCM key for the `sealed` part of records.
        case recordSealing = "atdrive record sealing v1"
        /// HMAC key that names chunks (`chunkID(for:)`).
        case chunkID = "atdrive chunk id v1"
        /// Seeds content-defined chunking, so chunk boundaries don't fingerprint files.
        case chunkerSeed = "atdrive chunker seed v1"
        /// Lets a device recognize a key it accepted before without storing the key (`fingerprint`).
        case fingerprint = "atdrive key fingerprint v1"
    }

    static let byteCount = 32

    private let key: SymmetricKey
    public let id: KeyID

    /// A new random key, for a new drive or a rotation.
    public init() {
        self.init(key: SymmetricKey(size: .bits256))
    }

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == Self.byteCount else {
            throw DriveCryptoError.invalidKey("a drive key is \(Self.byteCount) bytes, not \(rawRepresentation.count)")
        }
        self.init(key: SymmetricKey(data: rawRepresentation))
    }

    private init(key: SymmetricKey) {
        self.key = key
        let id = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, info: Data(Purpose.keyID.rawValue.utf8), outputByteCount: 8)
        self.id = KeyID(rawValue: id.withUnsafeBytes { $0.hexString })
    }

    /// The key's 32 bytes, to wrap or store. Handle with care.
    public var rawRepresentation: Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// The subkey for one purpose: HKDF-SHA256 of the drive key, with the purpose as `info` and
    /// no salt (the drive key is already uniformly random).
    public func subkey(_ purpose: Purpose, byteCount: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(purpose.rawValue.utf8), outputByteCount: byteCount)
    }

    /// The chunker's seed, as bytes: the chunker isn't a cipher, so it takes no `SymmetricKey`.
    public var chunkerSeed: Data {
        subkey(.chunkerSeed).withUnsafeBytes { Data($0) }
    }

    /// 32 bytes derived from the key, as hex. A device keeps the fingerprints of the keys it has
    /// accepted (never the keys), so it can tell that a keyring it's handed later still holds
    /// them: one the PDS made up, or an old one played back, doesn't. The key ID would do the same
    /// with 64 bits, which is in reach of a determined forger; this is 256.
    public var fingerprint: String {
        subkey(.fingerprint).withUnsafeBytes { $0.hexString }
    }

    /// Never the key itself, so logging one by mistake is harmless.
    public var description: String { "DriveKey(\(id))" }
}

/// Every drive key a device holds, oldest first. The newest one seals new records; any of them
/// opens old ones, found by key ID.
///
/// Removing a device rotates: a new key for new writes, which the removed device never gets. The
/// older keys stay, so everything written before can still be read.
public struct Keyring: Sendable, Equatable {
    /// Oldest first, never empty, no duplicates.
    public private(set) var keys: [DriveKey]

    /// A keyring holding one key, for a new drive.
    public init(_ key: DriveKey) {
        keys = [key]
    }

    /// Oldest first. Duplicates are dropped; an empty list is an error.
    public init(_ keys: [DriveKey]) throws {
        guard let first = keys.first else { throw DriveCryptoError.invalidKey("a keyring needs at least one key") }
        self.init(first)
        for key in keys.dropFirst() where self.key(id: key.id) == nil {
            self.keys.append(key)
        }
    }

    /// The key new records are sealed with.
    public var current: DriveKey { keys[keys.count - 1] }

    public func key(id: KeyID) -> DriveKey? {
        keys.last { $0.id == id }
    }

    /// Starts a new key for writes, keeping the old ones for reads.
    @discardableResult
    public mutating func rotate() -> DriveKey {
        let key = DriveKey()
        keys.append(key)
        return key
    }

    /// Adds the keys `other` has and this keyring doesn't, as newer than these, so no key is ever
    /// lost. If two devices rotated at once, they may each keep their own key as current; that's
    /// harmless, since both keyrings can then read everything.
    public mutating func merge(_ other: Keyring) {
        for key in other.keys where self.key(id: key.id) == nil {
            keys.append(key)
        }
    }
}

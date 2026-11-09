import Crypto
import Foundation

/// A keyring wrapped for one device, for its `me.jsnelgro.atdrive.device` record.
///
/// Each device has a Curve25519 key pair, made on the device and stored with its session (the raw
/// representations are what's stored). Wrapping is HPKE (RFC 9180) with X25519, HKDF-SHA256 and
/// ChaCha20-Poly1305, in auth mode: only the device can unwrap it, and unwrapping proves it was
/// wrapped by whoever holds the private key for `sender`.
///
/// That proof is the point. Anyone, the PDS included, can wrap a keyring of their own for a
/// device's public key. A device that used such a key for new writes would be sealing them for
/// the PDS. So before trusting what it unwraps, a device checks that `sender` is a device it
/// trusts: itself, or one whose pairing code it compared.
public struct WrappedKeyring: Codable, Sendable, Equatable {
    /// The raw public key of the device that wrapped it.
    public var sender: Bytes
    /// HPKE's `enc`: the ephemeral public key.
    public var encapsulatedKey: Bytes
    /// The keyring's keys, oldest first, 32 bytes each, then the 16-byte tag.
    public var ciphertext: Bytes

    public init(sender: Bytes, encapsulatedKey: Bytes, ciphertext: Bytes) {
        self.sender = sender
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    /// The sender's public key, to compare with the devices this one trusts.
    public var senderKey: Curve25519.KeyAgreement.PublicKey {
        get throws { try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sender.data) }
    }
}

/// A keyring wrapped with the recovery key, for the device record with rkey `recovery`.
///
/// AES-256-GCM under a key derived from the recovery key with HKDF-SHA256. Only someone with the
/// recovery key can make one, so unlike a device's, it needs no sender to check.
public struct RecoveryWrappedKeyring: Codable, Sendable, Equatable {
    /// A random 12-byte nonce, the ciphertext, then the 16-byte tag.
    public var sealed: Bytes

    public init(sealed: Bytes) {
        self.sealed = sealed
    }
}

extension Keyring {
    /// Wraps every key for `device`, authenticated as `sender` (this device's private key).
    public func wrapped(
        for device: Curve25519.KeyAgreement.PublicKey, from sender: Curve25519.KeyAgreement.PrivateKey
    ) throws -> WrappedKeyring {
        var hpke = try HPKE.Sender(
            recipientKey: device, ciphersuite: KeyWrapping.ciphersuite, info: KeyWrapping.info,
            authenticatedBy: sender)
        let ciphertext = try hpke.seal(rawRepresentation)
        return WrappedKeyring(
            sender: Bytes(sender.publicKey.rawRepresentation), encapsulatedKey: Bytes(hpke.encapsulatedKey),
            ciphertext: Bytes(ciphertext))
    }

    /// Unwraps a keyring wrapped for this device. Throws `DriveCryptoError.authenticationFailed`
    /// if it's for another device, was changed, or wasn't wrapped by `wrapped.sender`. Whether to
    /// trust that sender is the caller's decision (see `WrappedKeyring`).
    public init(unwrapping wrapped: WrappedKeyring, with device: Curve25519.KeyAgreement.PrivateKey) throws {
        let plaintext: Data
        do {
            var hpke = try HPKE.Recipient(
                privateKey: device, ciphersuite: KeyWrapping.ciphersuite, info: KeyWrapping.info,
                encapsulatedKey: wrapped.encapsulatedKey.data, authenticatedBy: try wrapped.senderKey)
            plaintext = try hpke.open(wrapped.ciphertext.data)
        } catch {
            throw DriveCryptoError.authenticationFailed
        }
        try self.init(rawRepresentation: plaintext)
    }

    /// Wraps every key with the recovery key.
    public func wrapped(for recoveryKey: RecoveryKey) throws -> RecoveryWrappedKeyring {
        try wrapped(for: recoveryKey, nonce: AES.GCM.Nonce())
    }

    /// With a chosen nonce, for known-answer tests only.
    func wrapped(for recoveryKey: RecoveryKey, nonce: AES.GCM.Nonce) throws -> RecoveryWrappedKeyring {
        let box = try AES.GCM.seal(
            rawRepresentation, using: recoveryKey.wrappingKey, nonce: nonce, authenticating: KeyWrapping.info)
        return RecoveryWrappedKeyring(sealed: Bytes(box.combined!))  // non-nil: the nonce is 12 bytes
    }

    /// Unwraps with the recovery key. Throws `DriveCryptoError.authenticationFailed` if it's the
    /// wrong recovery key, or the record was changed.
    public init(unwrapping wrapped: RecoveryWrappedKeyring, with recoveryKey: RecoveryKey) throws {
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped.sealed.data)
            plaintext = try AES.GCM.open(box, using: recoveryKey.wrappingKey, authenticating: KeyWrapping.info)
        } catch {
            throw DriveCryptoError.authenticationFailed
        }
        try self.init(rawRepresentation: plaintext)
    }

    /// The keys, oldest first, 32 bytes each: what gets wrapped. The order says which is current.
    var rawRepresentation: Data {
        keys.reduce(into: Data()) { $0.append($1.rawRepresentation) }
    }

    init(rawRepresentation: Data) throws {
        let raw = [UInt8](rawRepresentation)
        guard raw.count % DriveKey.byteCount == 0 else {
            throw DriveCryptoError.invalidKey("a keyring's length must be a multiple of \(DriveKey.byteCount)")
        }
        try self.init(
            stride(from: 0, to: raw.count, by: DriveKey.byteCount).map {
                try DriveKey(rawRepresentation: Data(raw[$0..<$0 + DriveKey.byteCount]))
            })
    }
}

enum KeyWrapping {
    static var ciphersuite: HPKE.Ciphersuite { .Curve25519_SHA256_ChachaPoly }
    /// HPKE's `info`, and the recovery wrap's associated data: what's wrapped, and in which format.
    static let info = Data("atdrive keyring v1".utf8)
}

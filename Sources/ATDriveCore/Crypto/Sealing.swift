import Crypto
import Foundation

/// The encrypted part of a record: everything the PDS doesn't need to see.
///
/// `sealed` is a JSON-encoded value, encrypted with AES-256-GCM under the drive key's
/// record-sealing subkey: a random 12-byte nonce, then the ciphertext, then the 16-byte tag. The
/// record's collection and rkey are the associated data, so the PDS can't move a sealed value to
/// another record (from one file to another, say) without it failing to open.
public struct SealedValue: Codable, Sendable, Equatable {
    /// The drive key it was sealed with.
    public var keyID: KeyID
    public var sealed: Bytes

    public init(keyID: KeyID, sealed: Bytes) {
        self.keyID = keyID
        self.sealed = sealed
    }
}

extension DriveKey {
    /// Seals `value` for the record at `collection`/`rkey`.
    public func seal<Value: Encodable>(_ value: Value, collection: String, rkey: String) throws -> SealedValue {
        try seal(value, collection: collection, rkey: rkey, nonce: AES.GCM.Nonce())
    }

    /// With a chosen nonce, for known-answer tests only: a nonce must never repeat under one key.
    func seal<Value: Encodable>(
        _ value: Value, collection: String, rkey: String, nonce: AES.GCM.Nonce
    ) throws -> SealedValue {
        let plaintext = try Sealing.encoder.encode(value)
        let box = try AES.GCM.seal(
            plaintext, using: subkey(.recordSealing), nonce: nonce,
            authenticating: Sealing.associatedData(collection: collection, rkey: rkey))
        return SealedValue(keyID: id, sealed: Bytes(box.combined!))  // non-nil: the nonce is 12 bytes
    }

    /// Opens a value sealed with this key for the record at `collection`/`rkey`.
    ///
    /// Throws `DriveCryptoError.unknownKeyID` if it was sealed with another key, and
    /// `.authenticationFailed` if it was changed, or sealed for another record.
    public func open<Value: Decodable>(
        _ sealed: SealedValue, as type: Value.Type = Value.self, collection: String, rkey: String
    ) throws -> Value {
        guard sealed.keyID == id else { throw DriveCryptoError.unknownKeyID(sealed.keyID) }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.sealed.data)
            plaintext = try AES.GCM.open(
                box, using: subkey(.recordSealing),
                authenticating: Sealing.associatedData(collection: collection, rkey: rkey))
        } catch {
            throw DriveCryptoError.authenticationFailed
        }
        // Authentic, so a decoding error here means a format this version doesn't understand.
        return try JSONDecoder().decode(type, from: plaintext)
    }
}

extension Keyring {
    /// Seals with the current key.
    public func seal<Value: Encodable>(_ value: Value, collection: String, rkey: String) throws -> SealedValue {
        try current.seal(value, collection: collection, rkey: rkey)
    }

    /// Opens with whichever key sealed it. Throws `DriveCryptoError.unknownKeyID` if that key isn't
    /// in this keyring, and `.authenticationFailed` if the value was changed or moved.
    public func open<Value: Decodable>(
        _ sealed: SealedValue, as type: Value.Type = Value.self, collection: String, rkey: String
    ) throws -> Value {
        guard let key = key(id: sealed.keyID) else { throw DriveCryptoError.unknownKeyID(sealed.keyID) }
        return try key.open(sealed, as: type, collection: collection, rkey: rkey)
    }
}

enum Sealing {
    /// Sorted keys, so the same value always seals the same plaintext (the known-answer tests
    /// rely on it).
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// `atdrive record v1`, the collection and the rkey, each ended by a zero byte. NSIDs and
    /// record keys can't contain one, so no two records share associated data.
    static func associatedData(collection: String, rkey: String) -> Data {
        var data = Data()
        for part in ["atdrive record v1", collection, rkey] {
            data.append(contentsOf: part.utf8)
            data.append(0)
        }
        return data
    }
}

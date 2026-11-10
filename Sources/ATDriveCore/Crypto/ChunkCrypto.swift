import Crypto
import Foundation

/// Names a chunk of file contents: HMAC-SHA256 of the plaintext under the drive key's chunk-ID
/// subkey. It's also all it takes to decrypt the chunk, so it lives only inside sealed records:
/// the PDS never sees one, and whoever is given a file's sealed metadata can read its chunks
/// without the drive key (which is how sharing a folder will work).
///
/// Encoded as standard base64 without padding: chunk lists can be long, and records are capped
/// at 1 MiB.
public struct ChunkID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Data

    static let byteCount = 32

    public init(rawValue: Data) throws {
        guard rawValue.count == Self.byteCount else {
            throw DriveCryptoError.invalidKey("a chunk ID is \(Self.byteCount) bytes, not \(rawValue.count)")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let data = Base64.decode(try container.decode(String.self)), data.count == Self.byteCount else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a chunk ID")
        }
        rawValue = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Base64.encode(rawValue))
    }

    /// Only the start: the whole ID decrypts the chunk, so it doesn't belong in logs.
    public var description: String { "ChunkID(\(Base64.encode(rawValue).prefix(8))…)" }
}

/// One chunk, encrypted: what's uploaded as a blob, and the ID that decrypts it.
public struct EncryptedChunk: Sendable, Equatable {
    public let id: ChunkID
    /// Ciphertext, then the 16-byte tag.
    public let ciphertext: Data
}

extension DriveKey {
    /// The ID of a chunk with these contents. Comparing IDs finds chunks the drive already has.
    public func chunkID(for plaintext: Data) -> ChunkID {
        let mac = HMAC<SHA256>.authenticationCode(for: plaintext, using: subkey(.chunkID))
        return try! ChunkID(rawValue: Data(mac))  // HMAC-SHA256 is always 32 bytes
    }

    /// Encrypts a chunk with keyed convergent encryption, as Tahoe-LAFS and borg do: the chunk's
    /// key is derived from its ID, and the ID from its contents.
    ///
    /// The nonce is fixed (all zeros). That's safe only because each key encrypts exactly one
    /// plaintext: a different plaintext has a different ID, so a different key. In exchange,
    /// identical chunks encrypt to identical bytes, so the PDS stores them once and uploads can
    /// skip them. Because the ID is keyed by the drive key, the PDS can't confirm a guess about
    /// what a chunk contains.
    public func encryptChunk(_ plaintext: Data) -> EncryptedChunk {
        let id = chunkID(for: plaintext)
        // AES-GCM fails only for oversized input (64 GiB), far beyond any chunk.
        let box = try! AES.GCM.seal(plaintext, using: id.chunkKey, nonce: ChunkID.nonce)
        // A fresh `Data`: `box.ciphertext` is a slice of the sealed box, starting at 12, and
        // appending to it would keep that start index, a trap for anyone indexing from 0.
        var ciphertext = Data(capacity: box.ciphertext.count + box.tag.count)
        ciphertext.append(contentsOf: box.ciphertext)
        ciphertext.append(contentsOf: box.tag)
        return EncryptedChunk(id: id, ciphertext: ciphertext)
    }
}

extension ChunkID {
    /// Decrypts a chunk from `encryptChunk(_:)`. Needs only the ID, not the drive key. Throws
    /// `DriveCryptoError.authenticationFailed` if the bytes were changed, or belong to another chunk.
    public func decrypt(_ ciphertext: Data) throws -> Data {
        do {
            let tagStart = ciphertext.endIndex - 16
            guard tagStart >= ciphertext.startIndex else { throw DriveCryptoError.authenticationFailed }
            let box = try AES.GCM.SealedBox(
                nonce: Self.nonce, ciphertext: ciphertext[..<tagStart], tag: ciphertext[tagStart...])
            return try AES.GCM.open(box, using: chunkKey)
        } catch {
            throw DriveCryptoError.authenticationFailed
        }
    }

    /// HKDF-SHA256 with the ID as input key material. The ID is a uniformly random-looking secret
    /// to anyone without the drive key, so it needs no salt.
    fileprivate var chunkKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawValue), info: Data("atdrive chunk key v1".utf8), outputByteCount: 32
        )
    }

    fileprivate static var nonce: AES.GCM.Nonce { try! AES.GCM.Nonce(data: Data(count: 12)) }
}

import Crypto
import Foundation

/// The key a drive is encrypted with: 32 random bytes, made when the drive is set up and kept on
/// each device that has unlocked it. The PDS only ever sees it wrapped by a passkey (see
/// `DriveUnlock`), so whoever runs the PDS can't read the drive.
///
/// Two keys are derived from it, so they're never used for two things:
/// - **records:** a file or folder's name, folder, size, hash and times (`Drive` seals them);
/// - **contents:** each chunk of a file.
public struct DriveKey: Sendable, Equatable {
    public let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == 32 else { throw ATDriveError.encryption("a drive key must be 32 bytes") }
        self.rawValue = rawValue
    }

    public static func random() -> DriveKey {
        try! DriveKey(rawValue: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// A short public name for the key, stored beside what it sealed, so "sealed with a key this
    /// device doesn't have" can be told apart from "damaged". Reveals nothing about the key.
    public var id: String { Base32.encode(derive("atdrive key id v1", bytes: 10).withUnsafeBytes { Data($0) }) }

    /// Seals a record's private fields. `context` names the record (its space, collection and
    /// key), so a sealed value can't be moved to another record without failing to open.
    func seal(_ plaintext: Data, context: String) -> Data {
        Sealed.seal(plaintext, key: derive("atdrive records v1"), context: context)
    }

    func open(_ sealed: Data, context: String) throws -> Data {
        try Sealed.open(sealed, key: derive("atdrive records v1"), context: context)
    }

    /// Encrypts one chunk of a file's contents.
    func encrypt(chunk: Data) -> Data {
        Sealed.seal(chunk, key: derive("atdrive contents v1"), context: "")
    }

    func decrypt(chunk: Data) throws -> Data {
        try Sealed.open(chunk, key: derive("atdrive contents v1"), context: "")
    }

    private func derive(_ purpose: String, bytes: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawValue), info: Data(purpose.utf8), outputByteCount: bytes)
    }
}

/// AES-256-GCM with a random 96-bit nonce: `[format 0x01][nonce 12][ciphertext][tag 16]`.
/// The format byte leaves room to change this without guessing what old data is.
enum Sealed {
    static let format: UInt8 = 1
    /// What sealing adds to the plaintext's length.
    static let overhead = 1 + 12 + 16

    static func seal(_ plaintext: Data, key: SymmetricKey, context: String) -> Data {
        let box = try! AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        return Data([format]) + box.combined!
    }

    static func open(_ sealed: Data, key: SymmetricKey, context: String) throws -> Data {
        guard sealed.count >= overhead, sealed.first == format else {
            throw ATDriveError.encryption("unknown encryption format")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw ATDriveError.encryption("couldn't decrypt: wrong key, or the data was changed")
        }
    }
}

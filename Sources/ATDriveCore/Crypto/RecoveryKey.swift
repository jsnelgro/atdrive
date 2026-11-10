import Crypto
import Foundation

/// Unlocks a drive when no device that holds its key is left: 256 random bits, shown once when the
/// drive is created, to write down. It's high-entropy, so it needs no password hashing.
///
/// Written as 56 Crockford base32 characters in 14 groups of 4: the key's 256 bits, then a 24-bit
/// checksum, so the last group (and a bit) is the checksum. Base32 rather than words, so there's
/// no word list to ship; Crockford's alphabet has no I, L, O or U, so there's little to misread.
public struct RecoveryKey: Sendable, Equatable, CustomStringConvertible {
    private let key: SymmetricKey

    static let byteCount = 32
    private static let checksumByteCount = 3
    private static let characterCount = 56  // (32 + 3) bytes × 8 / 5 bits, exactly
    private static let groupSize = 4

    /// A new random recovery key.
    public init() {
        key = SymmetricKey(size: .bits256)
    }

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == Self.byteCount else {
            throw DriveCryptoError.invalidKey(
                "a recovery key is \(Self.byteCount) bytes, not \(rawRepresentation.count)")
        }
        key = SymmetricKey(data: rawRepresentation)
    }

    /// Reads a recovery key as someone typed it: in any case, with or without spaces and dashes,
    /// and with I or L for 1 and O for 0. Throws `DriveCryptoError.recoveryKeyTypo` if it's
    /// well-formed but the checksum doesn't match, and `.invalidRecoveryKey` otherwise.
    public init(parsing text: String) throws {
        var values: [UInt8] = []
        for character in text.uppercased() where !character.isWhitespace && character != "-" {
            guard let value = Crockford.value(of: character) else {
                throw DriveCryptoError.invalidRecoveryKey("“\(character)” isn't used in recovery keys")
            }
            values.append(value)
        }
        guard values.count == Self.characterCount else {
            throw DriveCryptoError.invalidRecoveryKey(
                "it has \(values.count) letters and digits, and a recovery key has \(Self.characterCount)")
        }
        let bytes = Crockford.decode(values)
        let raw = Data(bytes.prefix(Self.byteCount))
        guard Data(bytes.suffix(Self.checksumByteCount)) == Self.checksum(of: raw) else {
            throw DriveCryptoError.recoveryKeyTypo
        }
        try self.init(rawRepresentation: raw)
    }

    public var rawRepresentation: Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// For writing down: `XXXX-XXXX-…`, 14 groups of 4.
    public var formatted: String {
        let characters = Array(Crockford.encode(rawRepresentation + Self.checksum(of: rawRepresentation)))
        return stride(from: 0, to: characters.count, by: Self.groupSize)
            .map { String(characters[$0..<$0 + Self.groupSize]) }
            .joined(separator: "-")
    }

    /// Never the key itself, so logging one by mistake is harmless.
    public var description: String { "RecoveryKey(…)" }

    /// The AES-GCM key that wraps the keyring for recovery.
    var wrappingKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, info: Data("atdrive recovery wrap v1".utf8), outputByteCount: 32)
    }

    /// A hash, not an error-correcting code: it can't say where the typo is, but it catches all
    /// but one in 16 million.
    private static func checksum(of raw: Data) -> Data {
        Data(SHA256.hash(data: Data("atdrive recovery key checksum v1".utf8) + raw).prefix(checksumByteCount))
    }
}

/// Crockford's base32 (https://www.crockford.com/base32.html), most significant bits first.
enum Crockford {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Bytes whose bit count is a multiple of 5, so there's no padding to worry about.
    static func encode(_ bytes: Data) -> String {
        precondition(bytes.count % 5 == 0)
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        return out
    }

    /// The inverse of `encode`, from the 5-bit values of a multiple of 8 characters.
    static func decode(_ values: [UInt8]) -> [UInt8] {
        precondition(values.count % 8 == 0)
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for value in values {
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    /// An uppercase character's value. I and L read as 1, and O as 0, as Crockford suggests.
    static func value(of character: Character) -> UInt8? {
        let normalized: Character =
            switch character {
            case "I", "L": "1"
            case "O": "0"
            default: character
            }
        return alphabet.firstIndex(of: normalized).map(UInt8.init)
    }
}

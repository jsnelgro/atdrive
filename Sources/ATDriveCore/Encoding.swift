import Crypto
import Foundation

/// RFC 4648 base32, lowercase, no padding: the encoding atproto uses for CIDs (`b…`).
enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    static func encode<S: Sequence<UInt8>>(_ bytes: S) -> String {
        var out: [UInt8] = []
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
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `nil` if it isn't lowercase base32.
    static func decode(_ text: String) -> [UInt8]? {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in text.utf8 {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}

/// Content identifiers for blobs, computed locally so we can check what the server stored and
/// what it sends back, without trusting either direction.
public enum CID {
    /// CIDv1, `raw` codec, sha2-256 multihash, base32: the format atproto uses for blobs.
    public static func forBlob(_ data: Data) -> String {
        forBlob(digest: SHA256.hash(data: data))
    }

    /// The hex SHA-256 of a blob, from its CID (CIDv1, raw, sha2-256, base32); `nil` for a CID
    /// of another kind.
    public static func sha256(ofBlob cid: String) -> String? {
        guard cid.hasPrefix("b"), let bytes = Base32.decode(String(cid.dropFirst())), bytes.count == 36,
            bytes[0] == 0x01, bytes[1] == 0x55, bytes[2] == 0x12, bytes[3] == 0x20
        else { return nil }
        return bytes[4...].hexString
    }

    static func forBlob(digest: SHA256.Digest) -> String {
        // version 1, codec raw (0x55), multihash sha2-256 (0x12) of length 32 (0x20)
        var bytes: [UInt8] = [0x01, 0x55, 0x12, 0x20]
        bytes.append(contentsOf: digest)
        return "b" + Base32.encode(bytes)
    }
}

extension Sequence<UInt8> {
    var hexString: String {
        map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }
}

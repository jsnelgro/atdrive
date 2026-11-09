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
}

/// Content identifiers for blobs, computed locally so we can check what the server stored and
/// what it sends back, without trusting either direction.
public enum CID {
    /// CIDv1, `raw` codec, sha2-256 multihash, base32: the format atproto uses for blobs.
    public static func forBlob(_ data: Data) -> String {
        forBlob(digest: SHA256.hash(data: data))
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

import Crypto
import Foundation

/// A short code to compare on two devices before one gives the other the drive key, so the PDS
/// can't swap in a public key of its own: 16 digits in groups of 4, from SHA-256 of the public key.
///
/// Why 16 and not 8: the PDS sees the new device's public key before the approving device does,
/// and can try keys of its own until one has the same code. 8 digits (27 bits) fall in minutes, or
/// at once with a precomputed table of a few gigabytes. 16 digits (53 bits) don't. A shorter code
/// would need a commit-then-reveal exchange, as Bluetooth pairing does.
public enum PairingCode {
    public static func make(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
        let digest = SHA256.hash(data: Data("atdrive pairing code v1".utf8) + publicKey.rawRepresentation)
        let number = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 10_000_000_000_000_000
        let digits = Array(String(number))
        let padded = Array(repeating: Character("0"), count: 16 - digits.count) + digits
        return stride(from: 0, to: 16, by: 4).map { String(padded[$0..<$0 + 4]) }.joined(separator: " ")
    }
}

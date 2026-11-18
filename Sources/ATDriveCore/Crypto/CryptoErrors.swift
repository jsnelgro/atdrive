/// Why something encrypted couldn't be read, or a key couldn't be used.
public enum DriveCryptoError: Error, Equatable, CustomStringConvertible {
    /// Sealed with a drive key this device doesn't have (yet): a newer key it hasn't been given,
    /// or one from before it lost access.
    case unknownKeyID(KeyID)
    /// Tampered with, moved to another record, or not meant for this key. AES-GCM can't tell
    /// these apart, and nobody should need to.
    case authenticationFailed
    /// Key material of the wrong size or shape.
    case invalidKey(String)
    /// Not a recovery key at all: the wrong length, or a character that isn't in the alphabet.
    case invalidRecoveryKey(String)
    /// A recovery key whose checksum doesn't match: almost certainly a typo.
    case recoveryKeyTypo

    public var description: String {
        switch self {
        case .unknownKeyID(let id): "sealed with a drive key this device doesn't have (\(id))"
        case .authenticationFailed: "can't be decrypted: damaged, tampered with, or for another key"
        case .invalidKey(let why): "invalid key: \(why)"
        case .invalidRecoveryKey(let why): "not a recovery key: \(why)"
        case .recoveryKeyTypo: "that recovery key has a typo (its checksum doesn't match)"
        }
    }
}

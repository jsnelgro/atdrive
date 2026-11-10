import Crypto
import Foundation

/// This device, as drives know it: an ID (the key of its device record), a name, and a Curve25519
/// key pair that the drive's keyring is wrapped for. And what it trusts (`trust`).
///
/// It's kept where the session is (`DeviceStore`: `device.json` beside `session.json`, or the
/// Mac's App Group container), never in the drive. The private key never leaves the device. The
/// keyring isn't kept here at all: it's unwrapped from the device's record each time the drive
/// is opened.
public struct DeviceIdentity: Codable, Sendable, Equatable, CustomStringConvertible {
    /// A TID, made with the identity. It's this device's record key in every drive.
    public let id: String
    /// Shown in device lists and pairing prompts, and recorded on every change it makes.
    public var name: String
    private let privateKeyData: Bytes
    public var trust: DeviceTrust

    /// A new device: a new ID and key pair.
    public init(name: String = DeviceName.current) {
        id = TID.next()
        self.name = name
        privateKeyData = Bytes(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        trust = DeviceTrust()
    }

    public var privateKey: Curve25519.KeyAgreement.PrivateKey {
        // Checked when decoded, and made here otherwise.
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData.data)
    }

    public var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    /// The public key as it's stored in records.
    public var publicKeyBytes: Bytes { Bytes(publicKey.rawRepresentation) }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case privateKeyData = "privateKey"
        case trust
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        privateKeyData = try container.decode(Bytes.self, forKey: .privateKeyData)
        trust = try container.decodeIfPresent(DeviceTrust.self, forKey: .trust) ?? DeviceTrust()
        guard (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData.data)) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .privateKeyData, in: container, debugDescription: "not a Curve25519 private key")
        }
    }

    /// Never the private key, so logging one by mistake is harmless.
    public var description: String { "DeviceIdentity(\(id), \(name))" }
}

/// What a device trusts in one drive, to decide whether to take a keyring wrapped for it
/// (`KeyTrust`). Only public things: no keys.
public struct DeviceTrust: Codable, Sendable, Equatable {
    /// The drive (its space URI) this is about. Trust in one drive says nothing about another.
    public var space: String?
    /// The public key of the device that approved this one, once the user compared their pairing
    /// code. It's trusted for this device's first keyring; after that, as any device in the
    /// roster is.
    public var approver: Bytes?
    /// The fingerprints (`DriveKey.fingerprint`) of every drive key this device has accepted. A
    /// keyring it's handed later must hold all of them.
    public var knownKeys: [String]

    public init(space: String? = nil, approver: Bytes? = nil, knownKeys: [String] = []) {
        self.space = space
        self.approver = approver
        self.knownKeys = knownKeys
    }

    /// What this says about `space`: nothing, if it's about another drive.
    func about(_ space: String) -> DeviceTrust {
        self.space == space ? self : DeviceTrust(space: space)
    }

    /// Having accepted `keyring` for `space`.
    func accepting(_ keyring: Keyring, in space: String) -> DeviceTrust {
        var trust = about(space)
        trust.knownKeys = keyring.keys.map(\.fingerprint)
        return trust
    }
}

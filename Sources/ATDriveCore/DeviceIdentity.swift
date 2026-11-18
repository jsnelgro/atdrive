import Crypto
import Foundation

/// This device, as drives know it: an ID (the key of its device record), a name, and a Curve25519
/// key pair that an encrypted drive's keyring is wrapped for. And what it trusts in each drive it
/// has held the keys of (`trust`). A drive that isn't encrypted needs none of it.
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
    /// What this device trusts, by drive (its space's URI). Trust in one says nothing about
    /// another.
    public var trust: [String: DeviceTrust]

    /// A new device: a new ID and key pair.
    public init(name: String = DeviceName.current) {
        id = TID.next()
        self.name = name
        privateKeyData = Bytes(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        trust = [:]
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
        do {
            trust = try container.decodeIfPresent([String: DeviceTrust].self, forKey: .trust) ?? [:]
        } catch DecodingError.typeMismatch where Self.isSingleDriveTrust(container) {
            // From before trust was kept per drive: one drive's, without saying which. Dropped.
            // That fails closed: an encrypted drive asks to approve this device again.
            trust = [:]
        }
        guard (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData.data)) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .privateKeyData, in: container, debugDescription: "not a Curve25519 private key")
        }
    }

    /// Whether `trust` has the shape it had before it was kept per drive: one `DeviceTrust`.
    private static func isSingleDriveTrust(_ container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        enum Old: CodingKey { case knownKeys }
        guard let old = try? container.nestedContainer(keyedBy: Old.self, forKey: .trust) else { return false }
        return (try? old.decode([String].self, forKey: .knownKeys)) != nil
    }

    /// Never the private key, so logging one by mistake is harmless.
    public var description: String { "DeviceIdentity(\(id), \(name))" }
}

/// What a device trusts in one drive, to decide whether to take a keyring wrapped for it
/// (`KeyTrust`), and whether to believe the drive stopped being encrypted (`Drive.open`). Only
/// public things: no keys. A device that has never held a drive's keys has none.
public struct DeviceTrust: Codable, Sendable, Equatable {
    /// The public key of the device that approved this one, once the user compared their pairing
    /// code. It's trusted for this device's first keyring; after that, as any device in the
    /// roster is.
    public var approver: Bytes?
    /// The fingerprints (`DriveKey.fingerprint`) of every drive key this device has accepted. A
    /// keyring it's handed later must hold all of them, and so must the keys published when
    /// encryption is turned off.
    public var knownKeys: [String]
    /// The newest settings this device has read (`DriveSettings.generation`). Older ones served
    /// later are an old copy played back, and are refused.
    public var settingsGeneration: Int?

    public init(approver: Bytes? = nil, knownKeys: [String] = [], settingsGeneration: Int? = nil) {
        self.approver = approver
        self.knownKeys = knownKeys
        self.settingsGeneration = settingsGeneration
    }

    /// Having accepted `keyring`.
    func accepting(_ keyring: Keyring) -> DeviceTrust {
        var trust = self
        trust.knownKeys = keyring.keys.map(\.fingerprint)
        return trust
    }

    private enum CodingKeys: String, CodingKey { case approver, knownKeys, settingsGeneration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approver = try container.decodeIfPresent(Bytes.self, forKey: .approver)
        knownKeys = try container.decodeIfPresent([String].self, forKey: .knownKeys) ?? []
        settingsGeneration = try container.decodeIfPresent(Int.self, forKey: .settingsGeneration)
    }
}

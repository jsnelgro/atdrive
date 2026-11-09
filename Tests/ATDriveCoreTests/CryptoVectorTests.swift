import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// Known answers, so the formats can't drift without a test failing: what's stored has to stay
/// readable. Expected values were computed independently with Python's `cryptography` (HKDF,
/// HMAC, AES-GCM, X25519), and HPKE's auth mode with a separate implementation of RFC 9180 checked
/// against that library's base mode.
@Suite struct CryptoVectorTests {
    private struct Sample: Codable, Equatable {
        var name: String
        var size: Int
    }

    private static func bytes(_ range: Range<Int>) -> Data { Data(range.map { UInt8($0) }) }
    private static func base64(_ string: String) -> Data { Base64.decode(string)! }

    let key = try! DriveKey(rawRepresentation: bytes(0..<32))
    let secondKey = try! DriveKey(rawRepresentation: bytes(100..<132))
    let recoveryKey = try! RecoveryKey(rawRepresentation: bytes(32..<64))
    let device = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(64..<96))

    @Test func keyIDsAndSubkeys() {
        #expect(key.id.rawValue == "19a109e328d0060e")
        #expect(secondKey.id.rawValue == "f213ce917cfeb78c")
        #expect(key.chunkerSeed.hexString == "9de4cb1a0dee7be65dcefed7a26e5202e428e9cfa2fc1f6c681516b9a6d896a3")
    }

    @Test func sealing() throws {
        let value = Sample(name: "notes.txt", size: 42)
        #expect(
            String(decoding: try Sealing.encoder.encode(value), as: UTF8.self) == #"{"name":"notes.txt","size":42}"#)
        let sealed = try key.seal(
            value, collection: "me.jsnelgro.atdrive.node", rkey: "3jzfcijpj2z2a",
            nonce: AES.GCM.Nonce(data: Self.bytes(0xa0..<0xac)))
        let expected = "oKGio6SlpqeoqaqrVgWNW76n6K8RN+nPsSg4pGsH2DBDWLKZ7L+FeP09p2BgvDq2M4meMSY36yXqoA"
        #expect(sealed == SealedValue(keyID: KeyID(rawValue: "19a109e328d0060e"), sealed: Bytes(Self.base64(expected))))
        #expect(try key.open(sealed, collection: "me.jsnelgro.atdrive.node", rkey: "3jzfcijpj2z2a") == value)
    }

    @Test func chunks() throws {
        let chunk = key.encryptChunk(Data("hello world".utf8))
        #expect(Base64.encode(chunk.id.rawValue) == "D8eYAVbzHBPtTPb8wF9ey4wVMFVNyzGL0QRQNKQv5+8")
        #expect(chunk.ciphertext.hexString == "2d3721082d09ecb9460eb8dfac731a504ddc3aca70ade9857fbdcf")
        #expect(try chunk.id.decrypt(chunk.ciphertext) == Data("hello world".utf8))
    }

    @Test func recoveryKeyText() throws {
        let text = "40GJ-48S4-4MK2-EA19-58NJ-RB9E-5WR3-2CHK-6GTK-CDSR-74X3-PF1X-7RZN-P166"
        #expect(recoveryKey.formatted == text)
        #expect(try RecoveryKey(parsing: text) == recoveryKey)
    }

    @Test func recoveryWrap() throws {
        let keyring = try Keyring([key, secondKey])
        let wrapped = try keyring.wrapped(for: recoveryKey, nonce: AES.GCM.Nonce(data: Self.bytes(0xb0..<0xbc)))
        let expected =
            "sLGys7S1tre4ubq7surOhXaASA0i+YRvE67fiKhkH9pNLk6FBBqqAy2JiCj/ZztusZ6BYJNd3mjWi4XFU6zpiVhHwxbpGkT7kgt9mmiaTWZbe05MmSy+Y5af0DQ"
        #expect(wrapped.sealed.data == Self.base64(expected))
        #expect(try Keyring(unwrapping: wrapped, with: recoveryKey) == keyring)
    }

    @Test func deviceWrap() throws {
        // HPKE's ephemeral key is random, so this checks unwrapping a keyring wrapped elsewhere.
        let wrapped = WrappedKeyring(
            sender: Bytes(Self.base64("ST6C/HRGSlkmiBdiPSBTxeuOLMSpiLT+4XnsawENUx0")),
            encapsulatedKey: Bytes(Self.base64("YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw")),
            ciphertext: Bytes(
                Self.base64(
                    "8CFL2gMlvLtMU3bDBS7JeIrRGS7W53D+virKRS4oGAhG2h9hYsvbGsclyyT956ORl32n+y5gvrW36XlCFcGVR9YwiB9AdlfCdapTf1H9Y38"
                )))
        let sender = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.bytes(128..<160))
        #expect(wrapped.sender.data == sender.publicKey.rawRepresentation)
        let keyring = try Keyring(unwrapping: wrapped, with: device)
        #expect(keyring.keys == [key, secondKey])
        #expect(keyring.current == secondKey)
    }

    @Test func pairingCode() {
        #expect(
            device.publicKey.rawRepresentation.hexString
                == "79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a")
        #expect(PairingCode.make(for: device.publicKey) == "7999 4500 7626 4087")
    }
}

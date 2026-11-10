import Crypto
import Foundation
import Testing

@testable import ATDriveCore

private struct Metadata: Codable, Equatable {
    var name: String
    var parent: String?
    var chunks: [ChunkID]
}

private let node = "me.jsnelgro.atdrive.node"

/// The same data with one bit flipped at `index`.
private func flipping(_ data: Data, at index: Int) -> Data {
    var copy = data
    copy[copy.startIndex + index] ^= 0x01
    return copy
}

private func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    var data = Data(capacity: count + 8)
    while data.count < count {
        withUnsafeBytes(of: generator.next() as UInt64) { data.append(contentsOf: $0) }
    }
    return data.prefix(count)
}

@Suite struct BytesTests {
    @Test func encodesAsDollarBytesWithoutPadding() throws {
        let json = try JSONEncoder().encode(Bytes(Data([1, 2, 3, 4])))
        #expect(String(decoding: json, as: UTF8.self) == #"{"$bytes":"AQIDBA"}"#)
    }

    @Test func decodesWithOrWithoutPadding() throws {
        for json in [#"{"$bytes":"AQIDBA"}"#, #"{"$bytes":"AQIDBA=="}"#] {
            #expect(try JSONDecoder().decode(Bytes.self, from: Data(json.utf8)).data == Data([1, 2, 3, 4]))
        }
        #expect(try JSONDecoder().decode(Bytes.self, from: Data(#"{"$bytes":""}"#.utf8)).data.isEmpty)
        for bad in [#"{"$bytes":"A"}"#, #"{"$bytes":"!!!!"}"#, #"{"bytes":"AQIDBA"}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Bytes.self, from: Data(bad.utf8)) }
        }
    }

    @Test func roundTrips() throws {
        for count in 0..<40 {
            let bytes = Bytes(randomData(count))
            #expect(try JSONDecoder().decode(Bytes.self, from: XRPCClient.encoder.encode(bytes)) == bytes)
        }
    }
}

@Suite struct DriveKeyTests {
    @Test func rawRepresentationRoundTrips() throws {
        let key = DriveKey()
        let copy = try DriveKey(rawRepresentation: key.rawRepresentation)
        #expect(copy == key)
        #expect(copy.id == key.id)
        #expect(key.rawRepresentation.count == 32)
        #expect(throws: DriveCryptoError.self) { try DriveKey(rawRepresentation: Data(count: 31)) }
    }

    @Test func newKeysDiffer() {
        let a = DriveKey()
        let b = DriveKey()
        #expect(a != b)
        #expect(a.id != b.id)
        #expect(a.id.rawValue.count == 16)
    }

    @Test func everyPurposeGetsItsOwnSubkey() {
        let key = DriveKey()
        let subkeys = DriveKey.Purpose.allCases.map { key.subkey($0).withUnsafeBytes { Data($0) } }
        #expect(Set(subkeys).count == DriveKey.Purpose.allCases.count)
        #expect(!subkeys.contains(key.rawRepresentation))
    }

    @Test func descriptionHidesTheKey() {
        let key = DriveKey()
        #expect("\(key)" == "DriveKey(\(key.id))")
        #expect("\(RecoveryKey())" == "RecoveryKey(…)")
    }
}

@Suite struct KeyringTests {
    @Test func rotationKeepsOldKeysForReading() throws {
        var keyring = Keyring(DriveKey())
        let first = keyring.current
        let old = try keyring.seal("old", collection: node, rkey: "a")
        let second = keyring.rotate()
        #expect(keyring.current == second)
        #expect(keyring.keys == [first, second])
        let new = try keyring.seal("new", collection: node, rkey: "b")
        #expect(old.keyID == first.id)
        #expect(new.keyID == second.id)
        #expect(try keyring.open(old, as: String.self, collection: node, rkey: "a") == "old")
        #expect(try keyring.open(new, as: String.self, collection: node, rkey: "b") == "new")
        #expect(keyring.key(id: first.id) == first)
    }

    @Test func needsAtLeastOneKeyAndDropsDuplicates() throws {
        #expect(throws: DriveCryptoError.self) { try Keyring([]) }
        let a = DriveKey()
        let b = DriveKey()
        #expect(try Keyring([a, b, a]).keys == [a, b])
    }

    @Test func mergingNeverLosesAKey() throws {
        let shared = DriveKey()
        var mine = Keyring(shared)
        var theirs = mine
        let myKey = mine.rotate()
        let theirKey = theirs.rotate()
        mine.merge(theirs)
        #expect(mine.keys == [shared, myKey, theirKey])
        var behind = Keyring(shared)
        behind.merge(mine)
        #expect(behind == mine)
    }
}

@Suite struct SealingTests {
    let keyring = Keyring(DriveKey())
    fileprivate let value = Metadata(
        name: "notes.txt", parent: "3jzfcijpj2z2a", chunks: [DriveKey().chunkID(for: Data("hi".utf8))])

    @Test func roundTrips() throws {
        let sealed = try keyring.seal(value, collection: node, rkey: "3jzfcijpj2z2b")
        #expect(sealed.keyID == keyring.current.id)
        #expect(try keyring.open(sealed, as: Metadata.self, collection: node, rkey: "3jzfcijpj2z2b") == value)
        // nonce (12) + JSON + tag (16)
        #expect(sealed.sealed.data.count == 12 + (try Sealing.encoder.encode(value)).count + 16)
    }

    @Test func recordJSON() throws {
        let sealed = try keyring.seal(value, collection: node, rkey: "r")
        let json = try XRPCClient.encoder.encode(sealed)
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(object["keyID"] as? String == keyring.current.id.rawValue)
        #expect((object["sealed"] as? [String: Any])?["$bytes"] is String)
        #expect(try JSONDecoder().decode(SealedValue.self, from: json) == sealed)
    }

    @Test func usesAFreshNonceEachTime() throws {
        let a = try keyring.seal(value, collection: node, rkey: "r")
        let b = try keyring.seal(value, collection: node, rkey: "r")
        #expect(a.sealed != b.sealed)
    }

    @Test func detectsEveryFlippedBit() throws {
        let sealed = try keyring.seal(value, collection: node, rkey: "r")
        // Every byte: the nonce, the ciphertext and the tag.
        for index in 0..<sealed.sealed.data.count {
            var tampered = sealed
            tampered.sealed = Bytes(flipping(sealed.sealed.data, at: index))
            #expect(throws: DriveCryptoError.authenticationFailed) {
                try keyring.open(tampered, as: Metadata.self, collection: node, rkey: "r")
            }
        }
        var truncated = sealed
        truncated.sealed = Bytes(sealed.sealed.data.prefix(20))
        #expect(throws: DriveCryptoError.authenticationFailed) {
            try keyring.open(truncated, as: Metadata.self, collection: node, rkey: "r")
        }
    }

    @Test func cantBeMovedToAnotherRecord() throws {
        let sealed = try keyring.seal(value, collection: node, rkey: "3jzfcijpj2z2a")
        #expect(throws: DriveCryptoError.authenticationFailed) {
            try keyring.open(sealed, as: Metadata.self, collection: node, rkey: "3jzfcijpj2z2b")
        }
        #expect(throws: DriveCryptoError.authenticationFailed) {
            try keyring.open(
                sealed, as: Metadata.self, collection: "me.jsnelgro.atdrive.version", rkey: "3jzfcijpj2z2a")
        }
        // The separator keeps collection and rkey apart: "ab" + "c" isn't "a" + "bc".
        let split = try keyring.seal(value, collection: "ab", rkey: "c")
        #expect(throws: DriveCryptoError.authenticationFailed) {
            try keyring.open(split, as: Metadata.self, collection: "a", rkey: "bc")
        }
    }

    @Test func unknownKeyIsNotTampering() throws {
        let stranger = Keyring(DriveKey())
        let sealed = try stranger.seal(value, collection: node, rkey: "r")
        #expect(throws: DriveCryptoError.unknownKeyID(stranger.current.id)) {
            try keyring.open(sealed, as: Metadata.self, collection: node, rkey: "r")
        }
        #expect(throws: DriveCryptoError.unknownKeyID(stranger.current.id)) {
            try keyring.current.open(sealed, as: Metadata.self, collection: node, rkey: "r")
        }
    }

    @Test func wrongKeyIDFailsAuthentication() throws {
        var rotated = keyring
        rotated.rotate()
        var sealed = try rotated.seal(value, collection: node, rkey: "r")
        sealed.keyID = rotated.keys[0].id  // names a key the reader has, but not the one used
        #expect(throws: DriveCryptoError.authenticationFailed) {
            try rotated.open(sealed, as: Metadata.self, collection: node, rkey: "r")
        }
    }
}

@Suite struct ChunkCryptoTests {
    let key = DriveKey()
    let plaintext = randomData(100_000)

    @Test func isDeterministicUnderOneDriveKey() throws {
        let a = key.encryptChunk(plaintext)
        let b = try DriveKey(rawRepresentation: key.rawRepresentation).encryptChunk(plaintext)
        #expect(a == b)
        #expect(a.id == key.chunkID(for: plaintext))
        #expect(a.ciphertext.count == plaintext.count + 16)
        #expect(a.ciphertext.prefix(plaintext.count) != plaintext)
    }

    @Test func differsUnderAnotherDriveKey() {
        let a = key.encryptChunk(plaintext)
        let b = DriveKey().encryptChunk(plaintext)
        #expect(a.id != b.id)
        #expect(a.ciphertext != b.ciphertext)
    }

    @Test func differsForOtherContents() {
        #expect(key.encryptChunk(plaintext).id != key.encryptChunk(flipping(plaintext, at: 500)).id)
    }

    @Test func decryptsFromItsIDAlone() throws {
        let chunk = key.encryptChunk(plaintext)
        // The ID as it would travel in sealed metadata, to someone without the drive key.
        let json = try JSONEncoder().encode([chunk.id])
        let id = try JSONDecoder().decode([ChunkID].self, from: json)[0]
        #expect(try id.decrypt(chunk.ciphertext) == plaintext)
        #expect(try id.decrypt(chunk.ciphertext[...]) == plaintext)
        #expect(try ChunkID(rawValue: chunk.id.rawValue).decrypt(chunk.ciphertext) == plaintext)
    }

    @Test func handlesEmptyAndLargeChunks() throws {
        let empty = key.encryptChunk(Data())
        #expect(empty.ciphertext.count == 16)
        #expect(try empty.id.decrypt(empty.ciphertext) == Data())
        let large = randomData(4 * 1024 * 1024)
        let chunk = key.encryptChunk(large)
        #expect(try chunk.id.decrypt(chunk.ciphertext) == large)
    }

    @Test func detectsTamperingAndTheWrongID() throws {
        let chunk = key.encryptChunk(plaintext)
        for index in [0, 1, plaintext.count / 2, plaintext.count - 1, plaintext.count, plaintext.count + 15] {
            #expect(throws: DriveCryptoError.authenticationFailed) {
                try chunk.id.decrypt(flipping(chunk.ciphertext, at: index))
            }
        }
        #expect(throws: DriveCryptoError.authenticationFailed) { try chunk.id.decrypt(chunk.ciphertext.dropLast()) }
        #expect(throws: DriveCryptoError.authenticationFailed) { try chunk.id.decrypt(Data(count: 15)) }
        let other = key.chunkID(for: Data("something else".utf8))
        #expect(throws: DriveCryptoError.authenticationFailed) { try other.decrypt(chunk.ciphertext) }
    }

    @Test func chunkIDJSON() throws {
        let id = key.chunkID(for: plaintext)
        let base64 = Base64.encode(id.rawValue)
        #expect(base64.count == 43)  // 32 bytes, unpadded
        #expect(String(decoding: try XRPCClient.encoder.encode([id]), as: UTF8.self) == "[\"\(base64)\"]")
        #expect("\(id)" == "ChunkID(\(base64.prefix(8))…)")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ChunkID].self, from: Data(#"["AQIDBA"]"#.utf8))
        }
        #expect(throws: DriveCryptoError.self) { try ChunkID(rawValue: Data(count: 16)) }
    }
}

@Suite struct DeviceKeyTests {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let approver = Curve25519.KeyAgreement.PrivateKey()

    var keyring: Keyring {
        var keyring = Keyring(DriveKey())
        keyring.rotate()
        keyring.rotate()
        return keyring
    }

    @Test func wrapsForADevice() throws {
        let keyring = keyring
        let wrapped = try keyring.wrapped(for: device.publicKey, from: approver)
        let unwrapped = try Keyring(unwrapping: wrapped, with: device)
        #expect(unwrapped == keyring)
        #expect(unwrapped.current == keyring.current)
        #expect(try wrapped.senderKey.rawRepresentation == approver.publicKey.rawRepresentation)
        // A device can wrap for itself, which is what its own record holds.
        #expect(try Keyring(unwrapping: keyring.wrapped(for: device.publicKey, from: device), with: device) == keyring)
    }

    @Test func survivesStorage() throws {
        let keyring = keyring
        let wrapped = try keyring.wrapped(for: device.publicKey, from: approver)
        let stored = try JSONDecoder().decode(WrappedKeyring.self, from: XRPCClient.encoder.encode(wrapped))
        let restored = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.rawRepresentation)
        #expect(try Keyring(unwrapping: stored, with: restored) == keyring)
    }

    @Test func onlyThatDeviceCanUnwrap() throws {
        let wrapped = try keyring.wrapped(for: device.publicKey, from: approver)
        #expect(throws: DriveCryptoError.authenticationFailed) {
            try Keyring(unwrapping: wrapped, with: Curve25519.KeyAgreement.PrivateKey())
        }
        #expect(throws: DriveCryptoError.authenticationFailed) { try Keyring(unwrapping: wrapped, with: approver) }
    }

    @Test func detectsTampering() throws {
        let wrapped = try keyring.wrapped(for: device.publicKey, from: approver)
        for index in [0, 31, 50, wrapped.ciphertext.data.count - 1] {
            var tampered = wrapped
            tampered.ciphertext = Bytes(flipping(wrapped.ciphertext.data, at: index))
            #expect(throws: DriveCryptoError.authenticationFailed) { try Keyring(unwrapping: tampered, with: device) }
        }
        var tampered = wrapped
        tampered.encapsulatedKey = Bytes(flipping(wrapped.encapsulatedKey.data, at: 3))
        #expect(throws: DriveCryptoError.authenticationFailed) { try Keyring(unwrapping: tampered, with: device) }
    }

    /// The PDS can wrap a keyring of its own for any device. It can't make it look like a device
    /// the reader trusts wrapped it.
    @Test func theSenderCantBeForged() throws {
        let pds = Curve25519.KeyAgreement.PrivateKey()
        var forged = try Keyring(DriveKey()).wrapped(for: device.publicKey, from: pds)
        #expect(try forged.senderKey.rawRepresentation != approver.publicKey.rawRepresentation)
        forged.sender = Bytes(approver.publicKey.rawRepresentation)
        #expect(throws: DriveCryptoError.authenticationFailed) { try Keyring(unwrapping: forged, with: device) }
    }

    /// Both devices show the same code, each from its own key and the other's; a key the PDS
    /// swapped in on either side changes it.
    @Test func pairingCodes() throws {
        let code = PairingCode.make(for: device.publicKey, and: approver.publicKey)
        #expect(code.wholeMatch(of: /\d{4} \d{4} \d{4} \d{4}/) != nil)
        #expect(PairingCode.make(for: approver.publicKey, and: device.publicKey) == code)
        let samePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey.rawRepresentation)
        #expect(PairingCode.make(for: samePublicKey, and: approver.publicKey) == code)
        let pds = Curve25519.KeyAgreement.PrivateKey().publicKey
        #expect(PairingCode.make(for: pds, and: approver.publicKey) != code)
        #expect(PairingCode.make(for: device.publicKey, and: pds) != code)
    }
}

@Suite struct RecoveryKeyTests {
    @Test func formattedRoundTrips() throws {
        for _ in 0..<50 {
            let key = RecoveryKey()
            let text = key.formatted
            #expect(text.wholeMatch(of: /([0-9A-HJKMNP-TV-Z]{4}-){13}[0-9A-HJKMNP-TV-Z]{4}/) != nil)
            #expect(try RecoveryKey(parsing: text) == key)
            #expect(try RecoveryKey(rawRepresentation: key.rawRepresentation) == key)
        }
    }

    @Test func parsingIsForgiving() throws {
        let key = try RecoveryKey(rawRepresentation: Data((32..<64).map { UInt8($0) }))
        let text = key.formatted  // 40GJ-48S4-…: has 0s and 1s to misread
        let variants = [
            text.lowercased(),
            text.replacingOccurrences(of: "-", with: " "),
            text.replacingOccurrences(of: "-", with: ""),
            "  " + text.replacingOccurrences(of: "-", with: "\n") + "\n",
            text.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l"),
            text.replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "I"),
        ]
        for variant in variants {
            #expect(try RecoveryKey(parsing: variant) == key)
        }
    }

    @Test func catchesTypos() throws {
        let key = RecoveryKey()
        let characters = Array(key.formatted.replacingOccurrences(of: "-", with: ""))
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for index in characters.indices {
            var typo = characters
            typo[index] = alphabet[(alphabet.firstIndex(of: typo[index])! + 1) % alphabet.count]
            #expect(throws: DriveCryptoError.recoveryKeyTypo) { try RecoveryKey(parsing: String(typo)) }
        }
        for index in characters.indices.dropLast() where characters[index] != characters[index + 1] {
            var swapped = characters
            swapped.swapAt(index, index + 1)
            #expect(throws: DriveCryptoError.recoveryKeyTypo) { try RecoveryKey(parsing: String(swapped)) }
        }
    }

    @Test func rejectsWhatIsntARecoveryKey() {
        let text = RecoveryKey().formatted
        func isInvalid(_ text: String) -> Bool {
            do {
                _ = try RecoveryKey(parsing: text)
                return false
            } catch DriveCryptoError.invalidRecoveryKey {
                return true
            } catch {
                return false
            }
        }
        for bad in [String(text.dropLast()), text + "0", "", "U" + text.dropFirst(), text.dropLast() + "!"] {
            #expect(isInvalid(bad), "\(bad)")
        }
        #expect(throws: DriveCryptoError.self) { try RecoveryKey(rawRepresentation: Data(count: 16)) }
    }

    @Test func wrapsTheKeyring() throws {
        var keyring = Keyring(DriveKey())
        keyring.rotate()
        let recoveryKey = RecoveryKey()
        let wrapped = try keyring.wrapped(for: recoveryKey)
        let stored = try JSONDecoder().decode(RecoveryWrappedKeyring.self, from: XRPCClient.encoder.encode(wrapped))
        let typedIn = try RecoveryKey(parsing: recoveryKey.formatted.lowercased())
        #expect(try Keyring(unwrapping: stored, with: typedIn) == keyring)
        #expect(throws: DriveCryptoError.authenticationFailed) { try Keyring(unwrapping: wrapped, with: RecoveryKey()) }
        var tampered = wrapped
        tampered.sealed = Bytes(flipping(wrapped.sealed.data, at: 20))
        #expect(throws: DriveCryptoError.authenticationFailed) { try Keyring(unwrapping: tampered, with: recoveryKey) }
    }
}

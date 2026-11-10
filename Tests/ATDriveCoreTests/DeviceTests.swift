import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// Keys and devices: creating a drive, unlocking a device with the recovery key or by approval,
/// whose keyrings a device takes, and removing a device.
@Suite struct DeviceTests {
    let pds = FakePDS()
    /// The device that created the drive.
    let laptop: Drive
    let recoveryKey: RecoveryKey
    let directory: URL

    init() async throws {
        laptop = pds.device("laptop")
        recoveryKey = try await laptop.create()
        directory = try temporaryDirectory()
    }

    func file(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func contents(_ node: Node, drive: Drive) async throws -> String {
        var data = Data()
        try await drive.read(node) { data += $0 }
        return String(decoding: data, as: UTF8.self)
    }

    /// The same device after a restart: its identity as saved, and nothing else.
    func restarted(_ drive: Drive) throws -> Drive {
        pds.device(drive.device, identity: try #require(drive.identity))
    }

    /// A new device, set up with the recovery key.
    func unlocked(_ name: String) async throws -> Drive {
        let device = pds.device(name)
        try await device.unlock(recoveryKey: recoveryKey)
        return device
    }

    /// `device` as `drive` lists it.
    func listed(_ device: Drive, by drive: Drive) async throws -> DeviceInfo {
        let id = try #require(device.identity?.id)
        return try #require(try await drive.devices().first { $0.id == id })
    }

    /// Writes a record straight to the PDS, as the PDS (or anyone with the account) could.
    func overwrite(_ collection: String, _ rkey: String, with record: some Encodable & Sendable) async throws {
        try await laptop.client.putSpaceRecord(
            space: laptop.space, repo: laptop.owner, collection: collection, rkey: rkey, record: record)
    }

    // MARK: Creating and the recovery key

    @Test func createThenUnlockWithTheRecoveryKey() async throws {
        let node = try await laptop.upload(try file("hello"), as: "a.txt", in: nil)
        #expect(try await restarted(laptop).unlock() == laptop.keyring)

        let phone = pds.device("phone")
        await #expect(throws: DriveAccessError.notApproved(pending: false)) { try await phone.unlock() }
        await #expect(throws: DriveAccessError.wrongRecoveryKey) {
            try await phone.unlock(recoveryKey: RecoveryKey())
        }
        try await phone.unlock(recoveryKey: recoveryKey)
        #expect(phone.keyring == laptop.keyring)
        #expect(try await contents(try #require(try await phone.tree().nodes[node.id]), drive: phone) == "hello")

        // It's in the roster, its record is wrapped by itself, and it opens again after a restart.
        #expect(try await laptop.devices().map(\.name) == ["laptop", "phone"])
        #expect(try await laptop.devices().allSatisfy(\.approved))
        #expect(try await restarted(phone).unlock() == phone.keyring)
        #expect(phone.identity?.trust.knownKeys == laptop.keyring?.keys.map(\.fingerprint))
        #expect(try await laptop.isRecoveryKey(recoveryKey))
    }

    @Test func aDriveIsCreatedOnce() async throws {
        await #expect(throws: DriveAccessError.driveExists) { try await pds.device("phone").create() }
        #expect(try await laptop.devices().map(\.name) == ["laptop"])
    }

    @Test func noDriveSaysSo() async throws {
        let empty = FakePDS()
        let device = empty.device("phone")
        await #expect(throws: DriveAccessError.noDrive) { try await device.unlock() }
        await #expect(throws: DriveAccessError.noDrive) { try await device.requestAccess() }
        await #expect(throws: DriveAccessError.noDrive) { try await device.unlock(recoveryKey: RecoveryKey()) }
    }

    @Test func aNewRecoveryKeyReplacesTheOld() async throws {
        let newKey = try await laptop.replaceRecoveryKey()
        #expect(try await !laptop.isRecoveryKey(recoveryKey))
        #expect(try await laptop.isRecoveryKey(newKey))
        let phone = pds.device("phone")
        await #expect(throws: DriveAccessError.wrongRecoveryKey) { try await phone.unlock(recoveryKey: recoveryKey) }
        try await phone.unlock(recoveryKey: newKey)
        #expect(phone.keyring == laptop.keyring)
    }

    // MARK: Approval

    @Test func approvalWithMatchingCodes() async throws {
        let phone = pds.device("phone")
        try await phone.requestAccess()
        await #expect(throws: DriveAccessError.notApproved(pending: true)) { try await phone.unlock() }
        #expect(try await phone.arrivedKeyring() == nil)

        // The laptop lists it as waiting, with the code over both keys.
        let waiting = try await listed(phone, by: laptop)
        #expect(!waiting.approved)
        let code = try waiting.pairingCode(with: try #require(laptop.identity))
        // The phone, while it waits, shows the same code for the laptop.
        let fromPhone = try await phone.devices().first { $0.name == "laptop" }
        #expect(try fromPhone?.pairingCode(with: try #require(phone.identity)) == code)

        try await laptop.approve(waiting)
        let arrived = try #require(try await phone.arrivedKeyring())
        #expect(arrived.sender.name == "laptop" && arrived.code == code)
        try await phone.accept(arrived)
        #expect(phone.keyring == laptop.keyring)
        #expect(phone.identity?.trust.approver == laptop.identity?.publicKeyBytes)
        #expect(try await laptop.devices().allSatisfy(\.approved))
        #expect(try await restarted(phone).unlock() == laptop.keyring)
    }

    /// The PDS can wrap a keyring of its own for a waiting device, and seal a roster with it that
    /// names its own key. The code for that sender then doesn't match what the laptop showed, and
    /// without the user's confirmation the keyring isn't taken.
    @Test func aKeyringFromOutsideTheRosterIsRejected() async throws {
        let phone = pds.device("phone")
        try await phone.requestAccess()
        let me = try #require(phone.identity)
        let attacker = Curve25519.KeyAgreement.PrivateKey()
        let forged = Keyring(DriveKey())

        // Wrapped by a key the drive's roster doesn't have: ignored.
        var record = DeviceRecord(name: me.name, publicKey: me.publicKeyBytes)
        record.keyring = try forged.wrapped(for: me.publicKey, from: attacker)
        try await overwrite(Lexicon.device, me.id, with: record)
        await #expect(throws: DriveAccessError.self) { try await phone.arrivedKeyring() }
        await #expect(throws: DriveAccessError.self) { try await phone.unlock() }

        // With a roster of its own, it gets as far as the code, which isn't the laptop's.
        let code = try await listed(phone, by: laptop).pairingCode(with: try #require(laptop.identity))
        let roster = DriveSettings(roster: [
            RosterEntry(id: "pds", name: "laptop", publicKey: Bytes(attacker.publicKey.rawRepresentation))
        ])
        try await overwrite(Lexicon.settings, Lexicon.settingsKey, with: try laptop.stored(roster, with: forged))
        let arrived = try #require(try await phone.arrivedKeyring())
        #expect(arrived.code != code)
        await #expect(throws: DriveAccessError.self) { try await phone.unlock() }  // not confirmed
        #expect(phone.keyring == nil)

        // Even after confirming the laptop: the sender has to be the device confirmed.
        var confirmed = me
        confirmed.trust = DeviceTrust(space: laptop.space, approver: try #require(laptop.identity?.publicKeyBytes))
        await #expect(throws: DriveAccessError.self) { try await pds.device("phone", identity: confirmed).unlock() }
    }

    /// A device that has the keys takes a keyring only if it holds every key it had: the PDS can't
    /// hand it one of its own, nor play back an old one from before a rotation.
    @Test func anUnlockedDeviceRejectsForgedAndOldKeyrings() async throws {
        let phone = try await unlocked("phone")
        let me = try #require(phone.identity)
        let original = try #require(pds.rawRecord(rkey: me.id, collection: Lexicon.device))

        // A made-up keyring, wrapped by a made-up device the forged roster names.
        let attacker = Curve25519.KeyAgreement.PrivateKey()
        let forged = Keyring(DriveKey())
        var record = DeviceRecord(name: me.name, publicKey: me.publicKeyBytes)
        record.keyring = try forged.wrapped(for: me.publicKey, from: attacker)
        try await overwrite(Lexicon.device, me.id, with: record)
        let roster = DriveSettings(roster: [
            RosterEntry(id: "x", name: "x", publicKey: Bytes(attacker.publicKey.rawRepresentation))
        ])
        let realSettings = try #require(pds.rawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings))
        try await overwrite(Lexicon.settings, Lexicon.settingsKey, with: try laptop.stored(roster, with: forged))
        await #expect(throws: DriveAccessError.keyringMissingKeys) { try await restarted(phone).unlock() }
        pds.insertRawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings, realSettings)

        // The laptop removes a third device: the keyring rotates, and the phone takes the new one.
        let tablet = try await unlocked("tablet")
        pds.insertRawRecord(rkey: me.id, collection: Lexicon.device, original)
        let old = try #require(pds.rawRecord(rkey: me.id, collection: Lexicon.device))
        try await laptop.remove(try #require(tablet.identity?.id), recoveryKey: recoveryKey)
        let running = try restarted(phone)
        let rotated = try await running.unlock()
        #expect(rotated.keys.count == 2 && rotated == laptop.keyring)
        let updated = try restarted(running)  // its trust now knows both keys
        // The old keyring played back: missing the new key, so it's refused.
        pds.insertRawRecord(rkey: me.id, collection: Lexicon.device, old)
        await #expect(throws: DriveAccessError.keyringMissingKeys) { try await updated.unlock() }
    }

    // MARK: Removing

    @Test func removeThenRotate() async throws {
        let phone = try await unlocked("phone")
        let tablet = try await unlocked("tablet")
        let before = try await laptop.upload(try file("aaaabbbb"), as: "before.txt", in: nil)
        var phoneView = try await phone.update(nil)
        var tabletView = try await tablet.update(nil)
        let tabletID = try #require(tablet.identity?.id)

        await #expect(throws: DriveAccessError.recoveryKeyNeeded) {
            try await laptop.remove(tabletID, recoveryKey: nil)
        }
        await #expect(throws: DriveAccessError.cannotRemoveThisDevice) {
            try await laptop.remove(try #require(laptop.identity?.id), recoveryKey: recoveryKey)
        }
        #expect(try await laptop.remove(tabletID, recoveryKey: recoveryKey))
        let keyring = try #require(laptop.keyring)
        #expect(keyring.keys.count == 2)
        #expect(try await laptop.devices().map(\.name) == ["laptop", "phone"])

        // New records are sealed with the new key; chunks keep their IDs (the first key's).
        let after = try await laptop.upload(try file("aaaabbbb"), as: "after.txt", in: nil)
        let sealed = try #require(pds.rawRecord(rkey: after.id)?["sealed"] as? [String: Any])
        #expect(sealed["keyID"] as? String == keyring.current.id.rawValue)
        #expect(after.record.chunks == before.record.chunks)

        // The phone, still running, picks up the new keyring and reads everything.
        phoneView = try await phone.update(phoneView)
        #expect(phone.keyring == keyring)
        #expect(phoneView.tree.unreadable.isEmpty && phoneView.history.unreadable.isEmpty)
        #expect(try await contents(try #require(phoneView.tree.nodes[after.id]), drive: phone) == "aaaabbbb")
        #expect(try await contents(try #require(phoneView.tree.nodes[before.id]), drive: phone) == "aaaabbbb")

        // The tablet still reads what was there before, but nothing sealed since.
        tabletView = try await tablet.update(tabletView)
        #expect(tablet.keyring?.keys.count == 1)
        #expect(tabletView.tree.nodes[before.id] != nil)
        #expect(tabletView.tree.unreadable[after.id]?.reason == .missingKey)
        #expect(tabletView.settings == nil)
        await #expect(throws: DriveAccessError.notApproved(pending: false)) { try await restarted(tablet).unlock() }
        // A keyring it wraps for the phone now is refused: it lacks the new key.
        let phoneIdentity = try #require(phone.identity)
        var record = try await laptop.devices().first { $0.id == phoneIdentity.id }.map {
            DeviceRecord(name: $0.name, publicKey: $0.publicKey)
        }
        record?.keyring = try tablet.keyring?.wrapped(
            for: phoneIdentity.publicKey, from: try #require(tablet.identity).privateKey)
        try await overwrite(Lexicon.device, phoneIdentity.id, with: try #require(record))
        await #expect(throws: DriveAccessError.keyringMissingKeys) { try await restarted(phone).unlock() }

        // The recovery key opens the new keyring.
        let fresh = try await unlocked("fresh")
        #expect(fresh.keyring == keyring)
    }

    @Test func removingAWaitingDeviceOnlyDeletesItsRequest() async throws {
        let phone = pds.device("phone")
        try await phone.requestAccess()
        let before = laptop.keyring
        #expect(try await !laptop.remove(try #require(phone.identity?.id), recoveryKey: nil))
        #expect(laptop.keyring == before)
        #expect(try await laptop.devices().map(\.name) == ["laptop"])
        await #expect(throws: DriveAccessError.noSuchDevice("nope")) {
            try await laptop.remove("nope", recoveryKey: nil)
        }
    }

    // MARK: Small parts

    @Test func theDeviceIsSavedPrivately() throws {
        let store = DeviceStore(directory: directory.appendingPathComponent("config"))
        #expect(try store.load() == nil)
        let made = try store.loadOrCreate(name: "laptop")
        #expect(try store.loadOrCreate() == made)
        #expect(made.name == "laptop" && TID.isValid(made.id))
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!"\(made)".contains(Base64.encode(made.privateKey.rawRepresentation)))
        var trusting = made
        trusting.trust = DeviceTrust(space: "at://x", approver: Bytes(Data([1])), knownKeys: ["ab"])
        try store.save(trusting)
        #expect(try store.load() == trusting)
    }

    @Test func trustDecisions() throws {
        let me = DeviceIdentity(name: "me")
        let other = Curve25519.KeyAgreement.PrivateKey()
        let keyring = Keyring(DriveKey())
        let space = "at://did:plc:test/space/x/default"
        let fromMe = try keyring.wrapped(for: me.publicKey, from: me.privateKey)
        let fromOther = try keyring.wrapped(for: me.publicKey, from: other)
        let member = RosterEntry(id: "o", name: "o", publicKey: Bytes(other.publicKey.rawRepresentation))
        func check(_ wrapped: WrappedKeyring, _ trust: DeviceTrust, roster: [RosterEntry] = [member])
            -> KeyTrust.Decision
        {
            var device = me
            device.trust = trust
            return KeyTrust.check(wrapped, keyring: keyring, device: device, space: space) { _ in roster }
        }
        let known = DeviceTrust(space: space, knownKeys: keyring.keys.map(\.fingerprint))
        #expect(check(fromMe, DeviceTrust()) == .accept)
        #expect(check(fromOther, DeviceTrust()) == .unknownSender)  // the roster alone isn't enough at first
        #expect(check(fromOther, DeviceTrust(space: space, approver: member.publicKey)) == .accept)
        #expect(check(fromOther, known) == .accept)
        #expect(check(fromOther, known, roster: []) == .unknownSender)
        let more = DeviceTrust(space: space, knownKeys: known.knownKeys + [DriveKey().fingerprint])
        #expect(check(fromMe, more) == .missingKnownKey)
        // Trust in another drive says nothing about this one.
        #expect(check(fromOther, DeviceTrust(space: "at://elsewhere", knownKeys: known.knownKeys)) == .unknownSender)
    }
}

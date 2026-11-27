import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// Keys and devices, on an encrypted drive: creating it, unlocking a device with the recovery key
/// or by approval, whose keyrings a device takes, and removing a device.
@Suite struct DeviceTests {
    let pds = FakePDS()
    /// The device that created the drive.
    let laptop: Drive
    let recoveryKey: RecoveryKey
    let directory: URL

    init() async throws {
        laptop = pds.unopened("laptop")
        recoveryKey = try #require(try await laptop.create(encrypted: true))
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
        pds.unopened(drive.device, identity: try #require(drive.identity))
    }

    /// A new device, set up with the recovery key.
    func unlocked(_ name: String) async throws -> Drive {
        let device = pds.unopened(name)
        try await device.unlock(recoveryKey: recoveryKey)
        return device
    }

    /// Opens the drive on `device`, and gives the keyring it then has.
    @discardableResult
    func opened(_ device: Drive) async throws -> Keyring? {
        try await device.open()
        return device.keyring
    }

    /// A device record the PDS made up: `key`'s, approved as far as `keyring` (its own) says.
    func forgedMember(_ id: String, name: String, key: Curve25519.KeyAgreement.PublicKey, keyring: Keyring) throws
        -> DeviceRecord
    {
        let member = RosterEntry(id: id, name: name, publicKey: Bytes(key.rawRepresentation))
        return DeviceRecord(
            name: name, publicKey: member.publicKey,
            member: try keyring.seal(member, space: FakePDS.space, collection: Lexicon.device, rkey: id))
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
        #expect(try await opened(restarted(laptop)) == laptop.keyring)

        let phone = pds.unopened("phone")
        await #expect(throws: DriveAccessError.notApproved(pending: false)) { try await phone.open() }
        await #expect(throws: DriveAccessError.wrongRecoveryKey) {
            try await phone.unlock(recoveryKey: RecoveryKey())
        }
        try await phone.unlock(recoveryKey: recoveryKey)
        #expect(phone.keyring == laptop.keyring)
        #expect(try await contents(try #require(try await phone.tree().nodes[node.id]), drive: phone) == "hello")

        // It's in the roster, its record is wrapped by itself, and it opens again after a restart.
        #expect(try await laptop.devices().map(\.name) == ["laptop", "phone"])
        #expect(try await laptop.devices().allSatisfy(\.approved))
        #expect(try await opened(restarted(phone)) == phone.keyring)
        #expect(phone.identity?.trust[laptop.space]?.knownKeys == laptop.keyring?.keys.map(\.fingerprint))
        #expect(try await laptop.isRecoveryKey(recoveryKey))
    }

    @Test func aDriveIsCreatedOnce() async throws {
        await #expect(throws: DriveAccessError.driveExists) { try await pds.unopened("phone").create() }
        #expect(try await laptop.devices().map(\.name) == ["laptop"])
    }

    @Test func noDriveSaysSo() async throws {
        let empty = FakePDS()
        let device = empty.unopened("phone")
        await #expect(throws: DriveAccessError.noDrive) { try await device.open() }
        await #expect(throws: DriveAccessError.noDrive) { try await device.requestAccess() }
        await #expect(throws: DriveAccessError.noDrive) { try await device.unlock(recoveryKey: RecoveryKey()) }
    }

    @Test func aNewRecoveryKeyReplacesTheOld() async throws {
        let newKey = try await laptop.replaceRecoveryKey()
        #expect(try await !laptop.isRecoveryKey(recoveryKey))
        #expect(try await laptop.isRecoveryKey(newKey))
        let phone = pds.unopened("phone")
        await #expect(throws: DriveAccessError.wrongRecoveryKey) { try await phone.unlock(recoveryKey: recoveryKey) }
        try await phone.unlock(recoveryKey: newKey)
        #expect(phone.keyring == laptop.keyring)
    }

    // MARK: Approval

    @Test func approvalWithMatchingCodes() async throws {
        let phone = pds.unopened("phone")
        try await phone.requestAccess()
        await #expect(throws: DriveAccessError.notApproved(pending: true)) { try await phone.open() }
        #expect(try await phone.arrivedKeyring() == nil)

        // The laptop lists it as waiting, with the code over both keys.
        let waiting = try await listed(phone, by: laptop)
        #expect(!waiting.approved)
        let code = try waiting.pairingCode(with: try #require(laptop.identity))
        // The phone, while it waits, shows the same code for the laptop (by its ID: the name of
        // an approved device is sealed).
        let laptopID = try #require(laptop.identity?.id)
        let fromPhone = try await phone.devices().first { $0.id == laptopID }
        #expect(fromPhone?.name == "device \(laptopID)")
        #expect(try fromPhone?.pairingCode(with: try #require(phone.identity)) == code)

        try await laptop.approve(waiting)
        let arrived = try #require(try await phone.arrivedKeyring())
        #expect(arrived.sender.name == "laptop" && arrived.code == code)
        try await phone.accept(arrived)
        #expect(phone.keyring == laptop.keyring)
        #expect(phone.identity?.trust[laptop.space]?.approver == laptop.identity?.publicKeyBytes)
        #expect(try await laptop.devices().allSatisfy(\.approved))
        #expect(try await opened(restarted(phone)) == laptop.keyring)
    }

    /// The PDS can wrap a keyring of its own for a waiting device, and seal a roster with it that
    /// names its own key. The code for that sender then doesn't match what the laptop showed, and
    /// without the user's confirmation the keyring isn't taken.
    @Test func aKeyringFromOutsideTheRosterIsRejected() async throws {
        let phone = pds.unopened("phone")
        try await phone.requestAccess()
        let me = try #require(phone.identity)
        let attacker = Curve25519.KeyAgreement.PrivateKey()
        let forged = Keyring(DriveKey())

        // Wrapped by a key the drive's roster doesn't have: ignored.
        var record = DeviceRecord(name: me.name, publicKey: me.publicKeyBytes)
        record.keyring = try forged.wrapped(for: me.publicKey, from: attacker, space: FakePDS.space)
        try await overwrite(Lexicon.device, me.id, with: record)
        await #expect(throws: DriveAccessError.self) { try await phone.arrivedKeyring() }
        await #expect(throws: DriveAccessError.self) { try await phone.open() }

        // With a roster of its own, it gets as far as the code, which isn't the laptop's.
        let code = try await listed(phone, by: laptop).pairingCode(with: try #require(laptop.identity))
        try await overwrite(
            Lexicon.device, "pds",
            with: try forgedMember("pds", name: "laptop", key: attacker.publicKey, keyring: forged))
        try await overwrite(
            Lexicon.settings, Lexicon.settingsKey, with: try laptop.stored(DriveSettings(), with: forged))
        let arrived = try #require(try await phone.arrivedKeyring())
        #expect(arrived.code != code)
        await #expect(throws: DriveAccessError.self) { try await phone.open() }  // not confirmed
        #expect(phone.keyring == nil)

        // Even after confirming the laptop: the sender has to be the device confirmed.
        var confirmed = me
        confirmed.trust[laptop.space] = DeviceTrust(approver: try #require(laptop.identity?.publicKeyBytes))
        await #expect(throws: DriveAccessError.self) { try await pds.unopened("phone", identity: confirmed).open() }
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
        record.keyring = try forged.wrapped(for: me.publicKey, from: attacker, space: FakePDS.space)
        try await overwrite(Lexicon.device, me.id, with: record)
        try await overwrite(
            Lexicon.device, "x", with: try forgedMember("x", name: "x", key: attacker.publicKey, keyring: forged))
        let realSettings = try #require(pds.rawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings))
        try await overwrite(
            Lexicon.settings, Lexicon.settingsKey, with: try laptop.stored(DriveSettings(), with: forged))
        await #expect(throws: DriveAccessError.keyringMissingKeys) { try await restarted(phone).open() }
        pds.insertRawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings, realSettings)
        pds.deleteRawRecord(rkey: "x", collection: Lexicon.device)

        // The laptop removes a third device: the keyring rotates, and the phone takes the new one.
        let tablet = try await unlocked("tablet")
        pds.insertRawRecord(rkey: me.id, collection: Lexicon.device, original)
        let old = try #require(pds.rawRecord(rkey: me.id, collection: Lexicon.device))
        try await laptop.remove(try #require(tablet.identity?.id), recoveryKey: recoveryKey)
        let running = try restarted(phone)
        let rotated = try #require(try await opened(running))
        #expect(rotated.keys.count == 1 && rotated == laptop.keyring)
        let updated = try restarted(running)  // its trust now knows the new key
        // The old keyring played back: missing the new key, so it's refused.
        pds.insertRawRecord(rkey: me.id, collection: Lexicon.device, old)
        await #expect(throws: DriveAccessError.keyringMissingKeys) { try await updated.open() }
    }

    // MARK: Removing

    @Test func removeThenRotate() async throws {
        let phone = try await unlocked("phone")
        let tablet = try await unlocked("tablet")
        let sleeper = try await unlocked("sleeper")  // offline from now until the end
        let before = try await laptop.upload(try file("aaaabbbb"), as: "before.txt", in: nil)
        _ = try await laptop.upload(try file("aaaabbbb, edited"), as: "before.txt", in: nil, replacing: before)
        var phoneView = try await phone.update(nil)
        var tabletView = try await tablet.update(nil)
        let tabletID = try #require(tablet.identity?.id)
        let oldKeyring = try #require(laptop.keyring)

        await #expect(throws: DriveAccessError.recoveryKeyNeeded) {
            try await laptop.remove(tabletID, recoveryKey: nil)
        }
        await #expect(throws: DriveAccessError.cannotRemoveThisDevice) {
            try await laptop.remove(try #require(laptop.identity?.id), recoveryKey: recoveryKey)
        }
        #expect(try await laptop.remove(tabletID, recoveryKey: recoveryKey))
        // A new keyring of one new key: the old keys are retired, and still read while what's
        // sealed with them is sealed again.
        let keyring = try #require(laptop.keyring)
        #expect(keyring.keys.count == 1 && oldKeyring.key(id: keyring.current.id) == nil)
        #expect(try await laptop.devices().map(\.name) == ["laptop", "phone", "sleeper"])
        var status = try await laptop.encryptionStatus()
        #expect(status.rotating && status.pending > 0 && !status.converting)

        // New records are sealed with the new key, and its chunks are named with it.
        let after = try await laptop.upload(try file("aaaabbbb"), as: "after.txt", in: nil)
        let sealed = try #require(pds.rawRecord(rkey: after.id)?["sealed"] as? [String: Any])
        #expect(sealed["keyID"] as? String == keyring.current.id.rawValue)
        #expect(after.record.chunks?.allSatisfy { $0.key == keyring.current.id } == true)

        // The phone, still running, picks up the new keyring and reads everything.
        phoneView = try await phone.update(phoneView)
        #expect(phone.keyring == keyring)
        #expect(phoneView.tree.unreadable.isEmpty && phoneView.history.unreadable.isEmpty)
        #expect(try await contents(try #require(phoneView.tree.nodes[after.id]), drive: phone) == "aaaabbbb")
        #expect(
            try await contents(try #require(phoneView.tree.nodes[before.id]), drive: phone) == "aaaabbbb, edited")

        // The tablet still reads what was there before, but nothing sealed since.
        tabletView = try await tablet.update(tabletView)
        #expect(tablet.keyring == oldKeyring)
        #expect(tabletView.tree.nodes[before.id] != nil)
        #expect(tabletView.tree.unreadable[after.id]?.reason == .missingKey)
        #expect(tabletView.settings == nil)
        await #expect(throws: DriveAccessError.notApproved(pending: false)) { try await restarted(tablet).open() }
        // A keyring it wraps for the phone now is refused: it lacks the new key.
        let phoneIdentity = try #require(phone.identity)
        let phoneRecord = try #require(pds.rawRecord(rkey: phoneIdentity.id, collection: Lexicon.device))
        var record = try await laptop.devices().first { $0.id == phoneIdentity.id }.map {
            DeviceRecord(name: $0.name, publicKey: $0.publicKey)
        }
        record?.keyring = try tablet.keyring?.wrapped(
            for: phoneIdentity.publicKey, from: try #require(tablet.identity).privateKey, space: FakePDS.space)
        try await overwrite(Lexicon.device, phoneIdentity.id, with: try #require(record))
        await #expect(throws: DriveAccessError.keyringMissingKeys) { try await restarted(phone).open() }
        pds.insertRawRecord(rkey: phoneIdentity.id, collection: Lexicon.device, phoneRecord)

        // Sealing everything again, history included: nothing is under the old keys any more.
        status = try await laptop.convert()
        #expect(status.isSettled && status.unreadable == 0)
        let stored = try await laptop.update(nil)
        let chunks =
            stored.tree.nodes.values.flatMap { $0.record.chunks ?? [] }
            + stored.history.versions(of: before.id).flatMap { $0.record.chunks ?? [] }
        #expect(!chunks.isEmpty && chunks.allSatisfy { $0.key == keyring.current.id })
        #expect(stored.history.versions(of: before.id).count == 2 && stored.history.unreadable.isEmpty)
        for id in [before.id, after.id] {
            let sealed = try #require(pds.rawRecord(rkey: id)?["sealed"] as? [String: Any])
            #expect(sealed["keyID"] as? String == keyring.current.id.rawValue)
        }
        let settings = try #require(stored.settings)
        #expect(settings.retiredKeys.isEmpty && !settings.rotating)
        #expect(Set(settings.formerKeys.map(\.id)) == Set(oldKeyring.keys.map(\.id)))

        // What the removed device writes now, with the key it kept, is refused, not read.
        let late = try await tablet.upload(try file("from the tablet"), as: "late.txt", in: nil)
        phoneView = try await phone.update(phoneView)
        #expect(phoneView.tree.nodes[late.id] == nil)
        #expect(phoneView.tree.unreadable[late.id]?.reason == .formerKey)
        #expect(try await contents(try #require(phoneView.tree.nodes[before.id]), drive: phone) == "aaaabbbb, edited")
        // A device that was offline throughout still takes the new keyring: the settings name
        // the keys it knew as the drive's former ones.
        #expect(try await opened(try restarted(sleeper)) == keyring)

        // The recovery key opens the new keyring.
        let fresh = try await unlocked("fresh")
        #expect(fresh.keyring == keyring)
    }

    @Test func rotatingTheKeysWithoutRemovingADevice() async throws {
        let phone = try await unlocked("phone")
        let node = try await laptop.upload(try file("aaaabbbb"), as: "a.txt", in: nil)
        let oldKeyring = try #require(laptop.keyring)
        #expect(try await laptop.encryptionStatus().pending == 0)
        let estimate = try await laptop.rotationEstimate()
        #expect(estimate.pending == 2 && estimate.pendingBytes == 8)  // the node and its version
        try await laptop.rotateKeys(recoveryKey: recoveryKey)
        let keyring = try #require(laptop.keyring)
        #expect(keyring != oldKeyring && keyring.keys.count == 1)
        #expect(try await laptop.devices().filter(\.approved).map(\.name) == ["laptop", "phone"])
        #expect(try await laptop.convert().isSettled)
        let view = try await phone.update(nil)
        #expect(phone.keyring == keyring)
        #expect(try await contents(try #require(view.tree.nodes[node.id]), drive: phone) == "aaaabbbb")
        #expect(try await unlocked("fresh").keyring == keyring)
    }

    /// Two devices replacing the keys at the same moment, one removing a device: the second
    /// one's write fails, and it replaces the keys again, from the first one's. One keyring that
    /// every device left accepts, and nothing unreadable once it's converted (#37).
    @Test func twoDevicesReplacingTheKeysAtOnce() async throws {
        let phone = try await unlocked("phone")
        let tablet = try await unlocked("tablet")
        let sleeper = try await unlocked("sleeper")  // offline throughout
        let node = try await laptop.upload(try file("aaaabbbb"), as: "a.txt", in: nil)
        let original = try #require(laptop.keyring)
        let (laptop, recoveryKey) = (laptop, recoveryKey)
        pds.meanwhile { try await laptop.rotateKeys(recoveryKey: recoveryKey) }
        #expect(try await phone.remove(try #require(tablet.identity?.id), recoveryKey: recoveryKey))
        pds.onRequest = nil
        let first = try #require(laptop.keyring)
        let keyring = try #require(phone.keyring)
        #expect(keyring.keys.count == 1 && first != keyring && first != original)
        #expect(original.key(id: keyring.current.id) == nil && first.key(id: keyring.current.id) == nil)
        let settings = try #require(try await phone.settings())
        #expect(settings.rotating)
        #expect(
            Set(settings.retiredKeys) == Set((original.keys + first.keys).map { Bytes($0.rawRepresentation) }))

        // The laptop writes with the keys it made, before it notices.
        let between = try await laptop.upload(try file("ccccdddd"), as: "between.txt", in: nil)
        #expect(try await opened(laptop) == keyring)
        #expect(try await opened(restarted(laptop)) == keyring)
        #expect(try await opened(restarted(phone)) == keyring)
        #expect(try await opened(restarted(sleeper)) == keyring)
        #expect(try await laptop.devices().filter(\.approved).map(\.name) == ["laptop", "phone", "sleeper"])
        #expect(try await unlocked("fresh").keyring == keyring)

        let status = try await phone.convert()
        #expect(status.isSettled && status.unreadable == 0)
        for device in [laptop, phone] {
            let view = try await device.update(nil)
            #expect(view.tree.unreadable.isEmpty && view.history.unreadable.isEmpty)
            #expect(try await contents(try #require(view.tree.nodes[node.id]), drive: device) == "aaaabbbb")
            #expect(try await contents(try #require(view.tree.nodes[between.id]), drive: device) == "ccccdddd")
        }
        await #expect(throws: DriveAccessError.self) { try await restarted(tablet).open() }
    }

    /// One device converting while another replaces the keys again: it doesn't end the other's
    /// rotation when it's done with its own; it carries on under the new keys.
    @Test func convertingWhileAnotherDeviceReplacesTheKeys() async throws {
        let phone = try await unlocked("phone")
        let node = try await laptop.upload(try file("aaaabbbb"), as: "a.txt", in: nil)
        try await laptop.rotateKeys(recoveryKey: recoveryKey)
        _ = try await opened(phone)
        let (laptop, recoveryKey) = (laptop, recoveryKey)
        pds.meanwhile { try await laptop.rotateKeys(recoveryKey: recoveryKey) }
        let status = try await phone.convert()
        pds.onRequest = nil
        let keyring = try #require(laptop.keyring)
        #expect(status.isSettled && status.unreadable == 0 && phone.keyring == keyring)
        let settings = try #require(try await laptop.settings())
        #expect(!settings.rotating && settings.retiredKeys.isEmpty)
        for device in [laptop, phone] {
            let view = try await device.update(nil)
            #expect(view.tree.unreadable.isEmpty && view.history.unreadable.isEmpty)
            #expect(try await contents(try #require(view.tree.nodes[node.id]), drive: device) == "aaaabbbb")
        }
    }

    /// A change to the settings writes a marker beside them, and deletes the one before: two
    /// devices that read the same settings can't both change them.
    @Test func aChangeToTheSettingsReplacesItsMarker() async throws {
        let read = try #require(try await laptop.settingsRecord())
        try await laptop.rotateKeys(recoveryKey: recoveryKey)
        let after = try #require(try await laptop.settingsRecord())
        let generation = try #require(try await laptop.settings()).generation
        #expect(after.markers == [SettingsRecord.marker(generation)])
        // A write based on what was read before is refused, and changes nothing.
        let stale = try #require(laptop.keyring)
        await #expect(throws: DriveAccessError.settingsChanged) {
            try await laptop.applyChangingSettings(
                [
                    .update(
                        collection: Lexicon.settings, rkey: Lexicon.settingsKey,
                        value: try laptop.stored(DriveSettings(generation: generation), with: stale))
                ], generation: generation, read: read)
        }
        #expect(try await laptop.settingsRecord()?.cid == after.cid)
    }

    @Test func droppingHistoryLeavesTheDriveAsItIs() async throws {
        let first = try await laptop.upload(try file("one"), as: "a.txt", in: nil)
        let node = try await laptop.upload(try file("two"), as: "a.txt", in: nil, replacing: first)
        let gone = try await laptop.upload(try file("gone"), as: "b.txt", in: nil)
        try await laptop.delete([gone])
        let snapshot = try await laptop.update(nil)
        #expect(snapshot.history.versions(of: node.id).count == 2)
        #expect(try await laptop.dropHistory(in: snapshot) > 0)
        let after = try await laptop.update(snapshot)
        #expect(after.history.versions(of: node.id).count == 1)
        #expect(after.history.versions(of: gone.id).isEmpty)
        #expect(after.trash().isEmpty)
        #expect(try await contents(try #require(after.tree.nodes[node.id]), drive: laptop) == "two")
    }

    @Test func removingAWaitingDeviceOnlyDeletesItsRequest() async throws {
        let phone = pds.unopened("phone")
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
        let store = DeviceStore(directory: directory.appendingPathComponent("state"))
        let file = directory.appendingPathComponent("state/device.json")
        #expect(try store.load() == nil)
        let made = try store.loadOrCreate(name: "laptop")
        #expect(try store.loadOrCreate() == made)
        #expect(made.name == "laptop" && TID.isValid(made.id))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!"\(made)".contains(Base64.encode(made.privateKey.rawRepresentation)))
        var trusting = made
        trusting.trust["at://x"] = DeviceTrust(approver: Bytes(Data([1])), knownKeys: ["ab"], settingsGeneration: 3)
        try store.save(trusting)
        #expect(try store.load() == trusting)
    }

    /// A device saved before trust was kept per drive still loads, with its ID and key, and no
    /// trust: an encrypted drive asks to approve it again.
    @Test func aDeviceFromBeforePerDriveTrustLoads() throws {
        let made = DeviceIdentity(name: "laptop")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(made)) as? [String: Any])
        json["trust"] = ["knownKeys": ["ab"], "settingsGeneration": 3]
        let loaded = try JSONDecoder().decode(DeviceIdentity.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.id == made.id && loaded.publicKeyBytes == made.publicKeyBytes)
        #expect(loaded.trust.isEmpty)

        json["trust"] = ["at://x": 3]  // anything else that doesn't fit is still an error
        let broken = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DeviceIdentity.self, from: broken) }
    }

    @Test func trustDecisions() throws {
        let me = DeviceIdentity(name: "me")
        let other = Curve25519.KeyAgreement.PrivateKey()
        let keyring = Keyring(DriveKey())
        let space = "at://did:plc:test/space/x/default"
        let fromMe = try keyring.wrapped(for: me.publicKey, from: me.privateKey, space: FakePDS.space)
        let fromOther = try keyring.wrapped(for: me.publicKey, from: other, space: FakePDS.space)
        let member = RosterEntry(id: "o", name: "o", publicKey: Bytes(other.publicKey.rawRepresentation))
        func check(
            _ wrapped: WrappedKeyring, _ trust: DeviceTrust?, in trusted: String = space,
            roster: [RosterEntry] = [member]
        )
            -> KeyTrust.Decision
        {
            var device = me
            device.trust[trusted] = trust
            return KeyTrust.check(wrapped, keyring: keyring, device: device, space: space) { _ in roster }
        }
        let known = DeviceTrust(knownKeys: keyring.keys.map(\.fingerprint))
        #expect(check(fromMe, nil) == .accept)
        #expect(check(fromOther, nil) == .unknownSender)  // the roster alone isn't enough at first
        #expect(check(fromOther, DeviceTrust(approver: member.publicKey)) == .accept)
        #expect(check(fromOther, known) == .accept)
        #expect(check(fromOther, known, roster: []) == .unknownSender)
        let more = DeviceTrust(knownKeys: known.knownKeys + [DriveKey().fingerprint])
        #expect(check(fromMe, more) == .missingKnownKey)
        // Trust in another drive says nothing about this one.
        #expect(check(fromOther, known, in: "at://elsewhere") == .unknownSender)
    }
}

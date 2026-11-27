import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// Plain drives, and turning encryption on and off: what the PDS stores either way, what happens
/// to what was there, what other devices make of it, and what the PDS can't fake.
@Suite struct SwitchingTests {
    let pds = FakePDS()
    let clock = TestClock(HistoryTests.start)
    let laptop: Drive
    let directory: URL

    /// Chunks big enough to hold the short files here whole, so a test can look for their
    /// contents in what the PDS stores.
    static let transfers = TransferOptions.fixed(64)

    init() async throws {
        laptop = pds.unopened("laptop", transfers: Self.transfers)
        directory = try temporaryDirectory()
    }

    /// Another device, which has yet to open the drive.
    func device(_ name: String) -> Drive { pds.unopened(name, transfers: Self.transfers) }

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
        pds.unopened(drive.device, transfers: drive.transfers, identity: try #require(drive.identity))
    }

    /// Whether anything the PDS stores (records or blobs) contains `text`.
    func stored(_ text: String) -> Bool {
        pds.everythingStored.contains { $0.range(of: Data(text.utf8)) != nil }
    }

    /// A drive with a folder, a file edited once (so its first contents are only in history), a
    /// file that was moved, and one in the trash.
    func populate(_ drive: Drive) async throws -> (edited: Node, moved: Node, deleted: Node) {
        let docs = try await drive.createFolder(named: "private-folder", in: nil)
        let first = try await drive.upload(try file("first draft, secret"), as: "notes.txt", in: docs.id)
        let edited = try await drive.upload(
            try file("second draft, secret"), as: "notes.txt", in: docs.id, replacing: first)
        let moved = try await drive.move(
            try await drive.upload(try file("moved contents"), as: "old-name.txt", in: nil), to: docs.id,
            as: "new-name.txt")
        let deleted = try await drive.upload(try file("deleted contents"), as: "gone.txt", in: nil)
        try await drive.delete([deleted])
        return (edited, moved, deleted)
    }

    /// Everything `populate` made still reads, history included.
    func expectIntact(_ drive: Drive, _ made: (edited: Node, moved: Node, deleted: Node)) async throws {
        let snapshot = try await drive.update(nil)
        #expect(snapshot.tree.unreadable.isEmpty && snapshot.history.unreadable.isEmpty)
        let edited = try #require(snapshot.tree.nodes[made.edited.id])
        #expect(try await contents(edited, drive: drive) == "second draft, secret")
        #expect(try await contents(try #require(snapshot.tree.nodes[made.moved.id]), drive: drive) == "moved contents")
        #expect(try snapshot.tree.locate(DrivePath("/private-folder/new-name.txt"))?.id == made.moved.id)
        // History: the first draft is still there to go back to, and the trash still holds its file.
        let versions = snapshot.history.versions(of: edited.id)
        #expect(versions.map(\.record.change) == [.created, .edited])
        let first = try #require(snapshot.history.record(at: versions[0]))
        #expect(try await contents(Node(id: edited.id, cid: "", record: first), drive: drive) == "first draft, secret")
        #expect(snapshot.trash().map(\.id) == [made.deleted.id])
        let restored = try await drive.restoreFromTrash([made.deleted.id], in: snapshot)
        #expect(try await contents(try #require(restored.restored.first), drive: drive) == "deleted contents")
        try await drive.delete(restored.restored)
    }

    // MARK: Plain drives

    @Test func aNewDriveIsPlainAndNeedsNoKeys() async throws {
        #expect(try await laptop.create() == nil)
        #expect(laptop.mode == .plain && laptop.keyring == nil)
        let node = try await laptop.upload(try file("readable contents"), as: "readable-name.txt", in: nil)

        // Stored as it is: the record's fields, and the file's bytes.
        let record = try #require(pds.rawRecord(rkey: node.id))
        #expect(record["name"] as? String == "readable-name.txt" && record["sealed"] == nil)
        #expect(record["sha256"] as? String == node.record.sha256)
        #expect(stored("readable contents"))
        #expect(node.record.chunks?.allSatisfy { !$0.isEncrypted } == true)
        #expect(pds.keys(in: Lexicon.device).isEmpty)

        // Any device signed in to the account just opens it.
        let phone = device("phone")
        #expect(try await phone.open() == .plain)
        #expect(
            try await contents(try #require(try await phone.tree().nodes[node.id]), drive: phone) == "readable contents"
        )
        try await phone.createFolder(named: "from the phone", in: nil)
        #expect(phone.identity?.trust.isEmpty == true)

        // It has no keys, devices or recovery key to manage.
        await #expect(throws: DriveAccessError.notEncrypted) { try await laptop.devices() }
        await #expect(throws: DriveAccessError.notEncrypted) { try await phone.requestAccess() }
        await #expect(throws: DriveAccessError.notEncrypted) { try await phone.unlock(recoveryKey: RecoveryKey()) }
        await #expect(throws: DriveAccessError.notEncrypted) { try await laptop.replaceRecoveryKey() }
        await #expect(throws: DriveAccessError.notEncrypted) { try await laptop.disableEncryption() }
    }

    @Test func aDriveThatIsNotOpenedCannotBeWrittenTo() async throws {
        try await laptop.create()
        let phone = device("phone")
        await #expect(throws: DriveAccessError.notOpened) { try await phone.createFolder(named: "x", in: nil) }
        await #expect(throws: DriveAccessError.notOpened) {
            try await phone.upload(try file("x"), as: "x.txt", in: nil)
        }
    }

    // MARK: Turning encryption on

    @Test func turningEncryptionOnEncryptsWhatIsThere() async throws {
        try await laptop.create()
        let made = try await populate(laptop)
        let driveID = try #require(try await laptop.settings()?.driveID)
        let phone = device("phone")
        try await phone.open()
        var phoneView = try await phone.update(nil)
        let before = try await laptop.update(nil)
        #expect(
            try await laptop.encryptionStatus()
                == EncryptionStatus(
                    mode: .plain, pending: 0, pendingBytes: 0, converting: false, unsealed: 0, unreadable: 0))

        // What turning it on will cost, to say before doing it: every record, every file's bytes.
        let estimate = try await laptop.conversionEstimate(to: .encrypted)
        #expect(estimate.pending == before.tree.nodes.count + before.history.versions.count)
        #expect(estimate.pendingBytes > 0 && laptop.mode == .plain)

        let recoveryKey = try await laptop.enableEncryption()
        #expect(laptop.mode == .encrypted && laptop.keyring != nil)
        #expect(try await laptop.encryptionStatus().pending == estimate.pending)
        await #expect(throws: DriveAccessError.alreadyEncrypted) { try await laptop.enableEncryption() }
        // Everything is still there and still plain: readable while it's converted.
        var status = try await laptop.encryptionStatus()
        #expect(status.mode == .encrypted && status.converting && status.pending > 0 && status.pendingBytes > 0)
        #expect(stored("second draft, secret") && stored("private-folder"))
        try await expectIntact(laptop, made)
        // What's written now is sealed.
        let fresh = try await laptop.upload(try file("written after"), as: "after.txt", in: nil)
        #expect(pds.rawRecord(rkey: fresh.id)?["sealed"] != nil && !stored("written after"))

        // The phone was using the drive plain. It notices, stops, and deletes nothing.
        phoneView = try await phone.update(phoneView)
        #expect(phone.mode == .encrypted && phone.keyring == nil)
        #expect(phone.accessProblem == .notApproved(pending: false))
        #expect(phoneView.tree.unreadable[fresh.id]?.reason == .missingKey)
        await #expect(throws: DriveAccessError.locked) { try await phone.createFolder(named: "x", in: nil) }

        status = try await laptop.convert()
        #expect(
            status
                == EncryptionStatus(
                    mode: .encrypted, pending: 0, pendingBytes: 0, converting: false, unsealed: 0, unreadable: 0))
        // Nothing readable is left on the PDS: no contents, no names, in files or history.
        for secret in [
            "first draft, secret", "second draft, secret", "moved contents", "deleted contents", "private-folder",
            "notes.txt", "old-name.txt", "new-name.txt", "gone.txt",
        ] {
            #expect(!stored(secret), "\(secret) is still readable")
        }
        // And nothing changed: the same drive, the same versions, the same contents.
        let after = try await laptop.update(nil)
        #expect(after.settings?.driveID == driveID && after.settings?.converting == false)
        #expect(Set(after.history.versions.keys).isSuperset(of: before.history.versions.keys))
        #expect(after.tree.nodes[made.edited.id]?.record.version == made.edited.record.version)
        try await expectIntact(laptop, made)
        #expect(try await laptop.settleRaces(in: try await laptop.update(nil)).isEmpty)
        // Running it again finds nothing to do.
        pds.resetCounts()
        #expect(try await laptop.convert().isSettled)
        #expect(pds.uploads == 0 && pds.count("com.atproto.space.applyWrites") == 0)

        // The phone gets in with the recovery key, as on any encrypted drive.
        try await phone.unlock(recoveryKey: recoveryKey)
        try await expectIntact(phone, made)
        #expect(try await laptop.devices().map(\.name) == ["laptop", "phone"])
    }

    /// The settings sealed when encryption is turned on come from the plain record, which the
    /// PDS could have changed: a short retention there isn't taken unless the user typed it.
    @Test func turningEncryptionOnSealsTheRetentionShown() async throws {
        try await laptop.create()
        func storeRetention(_ days: Int) async throws {
            var settings = try #require(try await laptop.update(nil).settings)
            settings.retentionDays = days
            try await laptop.client.putSpaceRecord(
                space: laptop.space, repo: laptop.owner, collection: Lexicon.settings, rkey: Lexicon.settingsKey,
                record: try laptop.stored(settings, with: nil))
        }
        try await storeRetention(1)  // the PDS's doing, say
        #expect(try await laptop.settingsToSeal().retentionDays == DriveSettings.defaultRetentionDays)
        #expect(try await laptop.settingsToSeal(retentionDays: 2).retentionDays == 2)
        try await storeRetention(14)
        #expect(try await laptop.settingsToSeal().retentionDays == 14)

        try await storeRetention(1)
        _ = try await laptop.enableEncryption()
        #expect(try await laptop.update(nil).settings?.retentionDays == DriveSettings.defaultRetentionDays)
        await #expect(throws: DriveAccessError.alreadyEncrypted) { try await laptop.settingsToSeal() }
    }

    @Test func aTypedRetentionIsSealed() async throws {
        try await laptop.create()
        _ = try await laptop.enableEncryption(retentionDays: 3)
        #expect(try await laptop.update(nil).settings?.retentionDays == 3)
    }

    @Test func convertingPicksUpWhereItStopped() async throws {
        try await laptop.create()
        let made = try await populate(laptop)
        _ = try await laptop.enableEncryption()
        // Cut off after a few writes, as a closed laptop would.
        pds.failingAfter["com.atproto.space.applyWrites"] = 2
        await #expect(throws: (any Error).self) { try await laptop.convert() }
        pds.failingAfter = [:]
        let midway = try await laptop.encryptionStatus()
        #expect(midway.converting && midway.pending > 0)
        try await expectIntact(laptop, made)  // a mix of plain and sealed, all readable

        // Another device with the keys can finish it.
        let desk = try restarted(laptop)
        #expect(try await desk.convert().isSettled)
        #expect(!stored("first draft, secret") && !stored("notes.txt"))
        try await expectIntact(laptop, made)
    }

    /// Once the drive has finished converting, a record that isn't sealed with its keys could be
    /// the PDS's, so devices ignore it (and never take it for a deletion) until the user says to
    /// keep it.
    @Test func unsealedRecordsAreIgnoredOnceTheDriveIsEncrypted() async throws {
        try await laptop.create()
        _ = try await laptop.enableEncryption()
        try await laptop.convert()
        // A device that hadn't noticed the switch writes a plain record. Or the PDS does.
        let straggler = pds.device("straggler", transfers: Self.transfers, mode: .plain)
        let late = try await straggler.upload(try file("written late"), as: "late.txt", in: nil)

        var snapshot = try await laptop.update(nil)
        #expect(snapshot.tree.nodes[late.id] == nil)
        #expect(snapshot.tree.unreadable[late.id]?.reason == .notSealed)
        var status = try await laptop.convert()
        #expect(status.unsealed == 2 && status.pending == 0 && !status.converting)  // the node, and its version
        #expect(stored("written late"))

        status = try await laptop.convert(adoptUnsealed: true)
        #expect(status.isSettled && status.unsealed == 0)
        snapshot = try await laptop.update(nil)
        #expect(try await contents(try #require(snapshot.tree.nodes[late.id]), drive: laptop) == "written late")
        #expect(!stored("written late") && !stored("late.txt"))
        #expect(snapshot.settings?.converting == false)
    }

    // MARK: Turning encryption off

    @Test func turningEncryptionOffIsOneWriteAndKeepsEverythingReadable() async throws {
        let recoveryKey = try #require(try await laptop.create(encrypted: true))
        let made = try await populate(laptop)
        let phone = device("phone")
        try await phone.unlock(recoveryKey: recoveryKey)
        var phoneView = try await phone.update(nil)
        let keys = try #require(laptop.keyring).keys
        let driveID = try #require(try await laptop.settings()?.driveID)
        #expect(!stored("second draft, secret"))

        pds.resetCounts()
        try await laptop.disableEncryption()
        #expect(pds.count("com.atproto.space.applyWrites") == 1 && pds.uploads == 0)
        #expect(laptop.mode == .plain && laptop.keyring == nil && laptop.identity?.trust.isEmpty == true)
        #expect(pds.keys(in: Lexicon.device).isEmpty)
        // The settings are plain, and publish the keys.
        let settings = try #require(try await laptop.settings())
        #expect(settings.driveID == driveID)
        #expect(settings.retiredKeys == keys.map { Bytes($0.rawRepresentation) })
        #expect(pds.rawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings)?["sealed"] == nil)
        // Nothing else was rewritten, and it all reads: with the published keys.
        #expect(pds.rawRecord(rkey: made.edited.id)?["sealed"] != nil)
        try await expectIntact(laptop, made)
        let fresh = try await laptop.upload(try file("plain again"), as: "plain.txt", in: nil)
        #expect(pds.rawRecord(rkey: fresh.id)?["name"] as? String == "plain.txt" && stored("plain again"))

        // The phone, still running with the keys, sees its keys published and follows.
        phoneView = try await phone.update(phoneView)
        #expect(phone.mode == .plain && phone.keyring == nil && phone.accessProblem == nil)
        #expect(phone.identity?.trust.isEmpty == true)
        #expect(phoneView.tree.unreadable.isEmpty && phoneView.tree.nodes[fresh.id] != nil)
        // A device that never had the keys opens it like any plain drive.
        let tablet = device("tablet")
        #expect(try await tablet.open() == .plain)
        try await expectIntact(tablet, made)

        // Converting rewrites what's sealed as plain records and plain blobs.
        var status = try await laptop.encryptionStatus()
        #expect(status.mode == .plain && status.pending > 0 && !status.converting)
        status = try await tablet.convert()
        #expect(status.pending == 0 && status.unreadable == 0)
        #expect(stored("first draft, secret") && stored("second draft, secret") && stored("deleted contents"))
        #expect(pds.rawRecord(rkey: made.edited.id)?["name"] as? String == "notes.txt")
        try await expectIntact(laptop, made)
        // The keys stay published: a device that was away can still see why the drive is plain.
        #expect(try await laptop.settings()?.retiredKeys.count == keys.count)
    }

    @Test func encryptionCanBeTurnedOnAgainWithNewKeys() async throws {
        let firstRecovery = try #require(try await laptop.create(encrypted: true))
        let made = try await populate(laptop)
        let oldKeys = try #require(laptop.keyring)
        try await laptop.disableEncryption()
        let secondRecovery = try await laptop.enableEncryption()
        let keyring = try #require(laptop.keyring)
        #expect(keyring.keys.count == 1 && oldKeys.key(id: keyring.current.id) == nil)
        try await expectIntact(laptop, made)  // sealed with the old, published keys: read while converting
        #expect(try await laptop.convert().isSettled)
        try await expectIntact(laptop, made)

        // Everything is under the new keys: the old ones, which the PDS has, open nothing.
        let snapshot = try await laptop.update(nil)
        for node in snapshot.tree.nodes.values {
            let sealed = try #require(pds.rawRecord(rkey: node.id)?["sealed"] as? [String: Any])
            #expect(sealed["keyID"] as? String == keyring.current.id.rawValue)
            #expect(node.record.chunks?.allSatisfy { $0.key == keyring.keys[0].id } != false)
        }
        let phone = device("phone")
        await #expect(throws: DriveAccessError.wrongRecoveryKey) { try await phone.unlock(recoveryKey: firstRecovery) }
        try await phone.unlock(recoveryKey: secondRecovery)
        try await expectIntact(phone, made)
    }

    // MARK: What the PDS can't do

    /// The PDS can replace the settings with plain ones. A device that held the keys believes the
    /// drive stopped being encrypted only if the settings publish those keys, which the PDS never
    /// had: otherwise it would start writing everything in the clear.
    @Test func thePDSCannotTurnEncryptionOff() async throws {
        _ = try await laptop.create(encrypted: true)
        let node = try await laptop.upload(try file("still secret"), as: "a.txt", in: nil)
        var view = try await laptop.update(nil)
        let real = try #require(pds.rawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings))

        for forged: [String: Any] in [
            ["$type": Lexicon.settings, "retentionDays": 30],
            // Publishing keys of its own doesn't help: they aren't the ones this device had.
            [
                "$type": Lexicon.settings, "retentionDays": 30,
                "retiredKeys": [["$bytes": Base64.encode(DriveKey().rawRepresentation)]],
            ],
        ] {
            pds.insertRawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings, forged)
            await #expect(throws: DriveAccessError.encryptionRemoved) { try await restarted(laptop).open() }
            // Still running, it carries on encrypted, and says so.
            view = try await laptop.update(view)
            #expect(laptop.mode == .encrypted && laptop.keyring != nil)
            #expect(laptop.accessProblem == .encryptionRemoved)
            let written = try await laptop.upload(try file("more secrets"), as: "b.txt", in: nil)
            #expect(pds.rawRecord(rkey: written.id)?["sealed"] != nil && !stored("more secrets"))
            #expect(view.tree.nodes[node.id] != nil)
        }
        // A device that never had the keys can't tell, and sees a plain drive it can't read much of.
        let stranger = device("stranger")
        #expect(try await stranger.open() == .plain)
        #expect(try await stranger.update(nil).tree.unreadable[node.id]?.reason == .missingKey)

        // The user can say it was them after all.
        let accepting = try restarted(laptop)
        try await accepting.acceptEncryptionRemoved()
        #expect(accepting.mode == .plain)
        // With the real settings back, all is as it was.
        pds.insertRawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings, real)
        #expect(try await restarted(laptop).open() == .encrypted)
    }

    /// While a drive converts, its devices read plain records. The PDS could serve those settings
    /// again later, to have its own plain records read: a device refuses settings older than ones
    /// it has seen.
    @Test func oldSettingsPlayedBackAreRefused() async throws {
        try await laptop.create()
        try await laptop.createFolder(named: "docs", in: nil)
        _ = try await laptop.enableEncryption()
        let whileConverting = try #require(pds.rawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings))
        try await laptop.convert()
        #expect(laptop.identity?.trust[laptop.space]?.settingsGeneration == 2)

        pds.insertRawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings, whileConverting)
        pds.insertRawRecord(
            rkey: "3aaaaaaaaaaa5", ["$type": Lexicon.node, "name": "forged", "kind": "folder", "createdAt": "2026"])
        await #expect(throws: DriveAccessError.settingsRolledBack) { try await restarted(laptop).open() }
        let view = try await laptop.update(try await laptop.update(nil))
        #expect(laptop.accessProblem == .settingsRolledBack)
        #expect(view.tree.unreadable["3aaaaaaaaaaa5"]?.reason == .notSealed)
    }

    /// A sealed record can't be moved into another drive that happens to have the same keys.
    @Test func sealedRecordsAreBoundToTheirSpace() async throws {
        _ = try await laptop.create(encrypted: true)
        let node = try await laptop.createFolder(named: "docs", in: nil)
        let keyring = try #require(laptop.keyring)
        let elsewhere = Drive(
            client: laptop.client, owner: laptop.owner, key: "another", device: "laptop", keyring: keyring)
        let value = try JSONValue(
            parsing: JSONSerialization.data(withJSONObject: try #require(pds.rawRecord(rkey: node.id))))
        guard case .readable = laptop.readNode(id: node.id, cid: node.cid, value: value) else {
            Issue.record("the drive can't read its own record")
            return
        }
        guard case .unreadable(let moved) = elsewhere.readNode(id: node.id, cid: node.cid, value: value) else {
            Issue.record("a record sealed for one space opened in another")
            return
        }
        #expect(moved.reason == .tampered)
    }

    // MARK: Devices

    /// Each device's membership is in its own record, so two devices approving at the same moment
    /// don't overwrite each other.
    @Test func approvalsAtTheSameMomentBothStand() async throws {
        let recoveryKey = try #require(try await laptop.create(encrypted: true))
        let desk = device("desk")
        try await desk.unlock(recoveryKey: recoveryKey)
        let phone = device("phone")
        let tablet = device("tablet")
        try await phone.requestAccess()
        try await tablet.requestAccess()
        // Both approvers read the drive's devices before either writes.
        let seenByLaptop = try await laptop.devices()
        let seenByDesk = try await desk.devices()
        try await laptop.approve(try #require(seenByLaptop.first { $0.name == "phone" }))
        try await desk.approve(try #require(seenByDesk.first { $0.name == "tablet" }))

        let devices = try await laptop.devices()
        #expect(devices.map(\.name) == ["desk", "laptop", "phone", "tablet"] && devices.allSatisfy(\.approved))
        for device in [phone, tablet] {
            try await device.accept(try #require(try await device.arrivedKeyring()))
            #expect(device.keyring == laptop.keyring)
        }
    }

    /// Removing a device changes the key, and memberships are sealed with the current key: the
    /// PDS can't bring a removed device back by restoring its old record.
    @Test func aRemovedDeviceCannotBeBroughtBack() async throws {
        let recoveryKey = try #require(try await laptop.create(encrypted: true))
        let tablet = device("tablet")
        try await tablet.unlock(recoveryKey: recoveryKey)
        let id = try #require(tablet.identity?.id)
        let old = try #require(pds.rawRecord(rkey: id, collection: Lexicon.device))
        #expect(try await laptop.remove(id, recoveryKey: recoveryKey))

        pds.insertRawRecord(rkey: id, collection: Lexicon.device, old)
        let listed = try #require(try await laptop.devices().first { $0.id == id })
        #expect(!listed.approved)
        // The next change of keys isn't wrapped for it either.
        let phone = device("phone")
        try await phone.unlock(recoveryKey: recoveryKey)
        #expect(try await laptop.remove(try #require(phone.identity?.id), recoveryKey: recoveryKey))
        #expect(try await laptop.devices().filter(\.approved).map(\.name) == ["laptop"])
        await #expect(throws: DriveAccessError.self) { try await restarted(tablet).open() }
        #expect(try await tablet.update(nil).settings == nil)
    }

    // MARK: Long chunk lists

    /// A chunk list long enough for `chunks` records is rewritten into new records, numbered
    /// after the old ones, and the file switches to them in one write.
    @Test func longChunkListsAreConvertedWhole() async throws {
        let tiny = TransferOptions(chunking: .init(minSize: 8, averageSize: 8, maxSize: 8), chunkListLimit: 420)
        let writer = Drive(
            client: laptop.client, owner: laptop.owner, transfers: tiny, device: "tiny records",
            identity: DeviceIdentity(name: "tiny records"))
        try await writer.create()
        let data = String(decoding: (0..<100).map { UInt8(65 + $0 % 26) }, as: UTF8.self)
        let node = try await writer.upload(try file(data), as: "long.bin", in: nil)
        let version = try #require(node.record.version)
        let plainCount = try #require(node.record.continuations)
        #expect(plainCount == 7 && node.record.continuationsFrom == nil)

        _ = try await writer.enableEncryption()
        #expect(try await writer.convert().isSettled)
        var snapshot = try await writer.update(nil)
        var converted = try #require(snapshot.tree.nodes[node.id])
        let sealedCount = try #require(converted.record.continuations)
        #expect(converted.record.continuationsFrom == plainCount + 1)
        #expect(snapshot.history.version(version)?.record.chunks == converted.record.chunks)
        #expect(
            pds.keys(in: Lexicon.chunks)
                == (plainCount + 1...plainCount + sealedCount).map { Lexicon.continuationKey(of: version, $0) }.sorted()
        )
        #expect(try await contents(converted, drive: writer) == data)
        #expect(!stored(String(data.prefix(8))))

        // And back, numbered on from there. A rename still points at the same records.
        try await writer.disableEncryption()
        #expect(try await writer.convert().pending == 0)
        snapshot = try await writer.update(nil)
        converted = try #require(snapshot.tree.nodes[node.id])
        #expect(converted.record.continuationsFrom == plainCount + sealedCount + 1)
        #expect(converted.record.continuations == plainCount)
        #expect(pds.keys(in: Lexicon.chunks).count == plainCount)
        let renamed = try await writer.move(converted, to: nil, as: "renamed.bin")
        #expect(try await contents(renamed, drive: writer) == data)
        #expect(
            try await contents(try #require(try await writer.update(nil).tree.nodes[node.id]), drive: writer) == data)
    }

    // MARK: The synced folder

    /// A synced folder whose drive gets encrypted by another device stops, keeps every local file,
    /// and carries on once this device has the keys.
    @Test func aSyncedFolderWaitsForTheKeysWhenItsDriveIsEncrypted() async throws {
        try await laptop.create()
        let folder = directory.appendingPathComponent("synced")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("local contents".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let device = device("server")
        try await device.open()
        let sync = try FolderSync(folder: folder, drive: device, settle: 0) { _ in }
        try await sync.sync()
        #expect(try await laptop.tree().children(of: nil).map(\.name) == ["a.txt"])

        let recoveryKey = try await laptop.enableEncryption()
        try await laptop.convert()
        try await laptop.upload(try file("from the laptop"), as: "b.txt", in: nil)
        await #expect(throws: DriveAccessError.notApproved(pending: false)) { try await sync.sync(checkRemote: true) }
        try Data("edited while locked".utf8).write(to: folder.appendingPathComponent("a.txt"))
        await #expect(throws: DriveAccessError.self) { try await sync.sync(checkRemote: true) }
        #expect(
            try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "edited while locked")
        #expect(!stored("edited while locked"))

        try await device.unlock(recoveryKey: recoveryKey)
        try await sync.sync(checkRemote: true)
        #expect(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8) == "from the laptop")
        let tree = try await laptop.update(nil).tree
        let edited = try #require(tree.child(named: "a.txt", in: nil))
        #expect(try await contents(edited, drive: laptop) == "edited while locked")
        #expect(!stored("edited while locked"))
    }
}

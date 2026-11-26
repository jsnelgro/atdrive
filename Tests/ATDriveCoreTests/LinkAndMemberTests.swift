import Foundation
import Testing

@testable import ATDriveCore

/// Links (#21) and sharing with people (#22), with three accounts: the owner (`did:plc:test`, its
/// drive in the test mode), Bob (a plain drive) and Carol (an encrypted one).
@Suite struct LinkAndMemberTests {
    let pds = FakePDS()
    let owner: JoinedDrive
    let bob: JoinedDrive
    let carol: JoinedDrive
    let bobDID: String
    let carolDID: String

    init() async throws {
        bobDID = pds.addAccount("bob")
        carolDID = pds.addAccount("carol")
        let home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        owner = JoinedDrive(home: home, access: pds.access())
        let bobs = pds.device("bob's", account: bobDID, mode: .plain)
        _ = try await bobs.create(encrypted: false)
        bob = JoinedDrive(home: bobs, access: pds.access(as: bobDID))
        let carols = pds.unopened("carol's", account: carolDID)
        _ = try await carols.create(encrypted: true)
        carol = JoinedDrive(home: carols, access: pds.access(as: carolDID))
        for drive in [owner, bob, carol] { try await drive.ensureSharingKey() }
    }

    func file(_ contents: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("f.txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// `/photos` with `a.txt` and `trip/b.txt`, shared.
    func sharedPhotos() async throws -> Node {
        let photos = try await owner.createFolder(named: "photos", in: nil)
        _ = try await owner.upload(try file("aaa"), as: "a.txt", in: photos.id)
        let trip = try await owner.createFolder(named: "trip", in: photos.id)
        _ = try await owner.upload(try file("bbb"), as: "b.txt", in: trip.id)
        return try await owner.share(photos)
    }

    func contents(_ drive: JoinedDrive, _ path: String) async throws -> String? {
        let tree = try await drive.tree()
        guard let node = try? tree.locate(DrivePath(path)) else { return nil }
        var data = Data()
        try await drive.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Links

    @Test func linksRoundTrip() throws {
        let space = XRPCClient.spaceURI(authority: "did:plc:abc", type: Lexicon.driveSpace, key: "k1")
        let key = ShareLink.newKey()
        let link = ShareLinkAddress(space: space, key: key)
        #expect(link.description.hasPrefix("atdrive://open?at=at%3A%2F%2Fdid%3Aplc%3Aabc%2Fspace%2F"))
        #expect(try ShareLinkAddress(parsing: link.description) == link)
        #expect(try ShareLinkAddress(parsing: space) == ShareLinkAddress(space: space))
        #expect(throws: ATDriveError.self) { try ShareLinkAddress(parsing: "https://example.com") }
        let other = try ShareLinkAddress(parsing: "at://did:plc:abc/space/com.example.board/b1")
        #expect(!other.isDrive)
    }

    /// A link with the space in the PDS's form (`at:space/…`), as a newer client may make: the
    /// same space, in ATDrive's form.
    @Test func linksInThePDSsFormOpenTheSameSpace() throws {
        let space = XRPCClient.spaceURI(authority: "did:plc:abc", type: Lexicon.driveSpace, key: "k1")
        let wire = "at:space/did:plc:abc/\(Lexicon.driveSpace)/k1"
        #expect(try ShareLinkAddress(parsing: wire).space == space)
        #expect(
            try ShareLinkAddress(parsing: "atdrive://open?at=at%3Aspace%2Fdid%3Aplc%3Aabc%2F\(Lexicon.driveSpace)%2Fk1")
                .space == space)
        #expect(throws: ATDriveError.self) { try ShareLinkAddress(parsing: "at:space/did:plc:abc/only-two") }
    }

    /// A link to your own share is refused, though the share is in your drive (as yours).
    @Test func yourOwnLinkIsRefused() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        #expect(owner.isOwn(link) && !bob.isOwn(link))
        await #expect(throws: LinkError.yourOwn) { try await owner.add(link) }
        #expect(try await owner.path(of: link) == DrivePath("/photos"))
        #expect(try await owner.tree().nodes.values.filter(\.isMount).count == 1, "nothing added")
    }

    @Test func aPublicLinkReadsSignedOut() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        #expect((link.key != nil) == TestMode.encrypted)
        #expect(try await owner.link(of: mount) == link)

        let opened = try await JoinedDrive.open(link, access: pds.access(as: nil))
        #expect(opened.name == "photos" && opened.owner == FakePDS.defaultDID)
        let tree = try await opened.drive.tree()
        let b = try #require(try tree.locate(DrivePath("/trip/b.txt")))
        var data = Data()
        try await opened.drive.read(b) { data.append($0) }
        #expect(String(decoding: data, as: UTF8.self) == "bbb")
    }

    @Test func anEncryptedLinkWithoutItsKeyFailsClearly() async throws {
        guard TestMode.encrypted else { return }
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        await #expect(throws: SharingError.linkKeyMissing) {
            _ = try await JoinedDrive.open(ShareLinkAddress(space: link.space), access: pds.access(as: nil))
        }
        await #expect(throws: SharingError.linkKeyWrong) {
            _ = try await JoinedDrive.open(
                ShareLinkAddress(space: link.space, key: ShareLink.newKey()), access: pds.access(as: nil))
        }
    }

    @Test func openingALinkMountsItReadOnlyInPlainAndEncryptedDrives() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        for recipient in [bob, carol] {
            let added = try await recipient.add(link)
            #expect(added.isMount && added.name == "photos")
            #expect(try await recipient.add(link).id == added.id, "added once")
            #expect(try await contents(recipient, "/photos/trip/b.txt") == "bbb")
            // Read-only.
            let folder = try #require(try await recipient.tree().locate(DrivePath("/photos")))
            await #expect(throws: ATDriveError.self) { _ = try await recipient.createFolder(named: "x", in: folder.id) }
        }
        // A plain drive keeps the link key readable; an encrypted one seals it.
        let bobsMount = try #require(try await bob.home.update(nil).tree.nodes.values.first(where: \.isMount))
        #expect((bobsMount.record.mount?.linkKey != nil) == TestMode.encrypted)
        // The owner's changes come through.
        _ = try await owner.upload(try file("ccc"), as: "c.txt", in: mount.id)
        #expect(try await contents(bob, "/photos/c.txt") == "ccc")
    }

    @Test func aNameThatsTakenGetsANumber() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        _ = try await bob.createFolder(named: "photos", in: nil)
        #expect(try await bob.add(link).name == "photos (2)")
    }

    @Test func turningTheLinkOffLeavesWhatWasOpened() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        _ = try await bob.add(link)
        let folder = try temporaryDirectory().appendingPathComponent("bob")
        do {
            let sync = try FolderSync(folder: folder, drive: bob, settle: 0)
            try await sync.sync()
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))

            try await owner.turnLinkOff(mount)
            #expect(try await owner.link(of: mount) == nil)
            try await sync.sync()
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))
            let state = try await bob.update(nil).mounts.values.first
            #expect(state?.problem == .access(.notShared))
        }
        await #expect { _ = try await JoinedDrive.open(link, access: pds.access(as: nil)) } throws: {
            SpaceAccessProblem($0) == .notShared
        }
    }

    @Test func aDeletedShareGoesFromRecipients() async throws {
        let mount = try await sharedPhotos()
        _ = try await bob.add(try await owner.turnLinkOn(mount))
        let folder = try temporaryDirectory().appendingPathComponent("bob")
        let sync = try FolderSync(folder: folder, drive: bob, settle: 0)
        try await sync.sync()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))
        try await owner.client.deleteSpace(mount.record.mount!.space)
        try await sync.sync()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))
        #expect(try await bob.update(nil).mounts.values.first?.problem == .access(.deleted))
    }

    // MARK: People

    @Test func membersReadAndOthersDont() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID, carolDID], to: mount)
        let address = ShareLinkAddress(space: mount.record.mount!.space)
        for member in [bob, carol] {
            _ = try await member.add(address)
            #expect(try await contents(member, "/photos/trip/b.txt") == "bbb")
        }
        let dave = JoinedDrive(
            home: pds.device("dave's", account: pds.addAccount("dave"), mode: .plain),
            access: pds.access(as: "did:plc:dave"))
        _ = try await dave.home.create(encrypted: false)
        await #expect { _ = try await dave.add(address) } throws: { SpaceAccessProblem($0) == .notShared }
        #expect(Set(try await owner.members(of: mount).map(\.did)) == [bobDID, carolDID])
    }

    @Test func aRemovedMemberIsHeldAndGetsNothingNew() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID, carolDID], to: mount)
        _ = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))
        _ = try await carol.add(ShareLinkAddress(space: mount.record.mount!.space))
        let folder = try temporaryDirectory().appendingPathComponent("bob")
        do {
            let sync = try FolderSync(folder: folder, drive: bob, settle: 0)
            try await sync.sync()

            try await owner.removeMembers([bobDID], from: mount)
            _ = try await owner.upload(try file("after"), as: "after.txt", in: mount.id)
            try await sync.sync()
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/after.txt").path))
            #expect(try await bob.update(nil).mounts.values.first?.problem == .access(.notShared))
        }
        // Carol stays, and reads what's new (with the new key, if encrypted).
        #expect(try await contents(carol, "/photos/after.txt") == "after")
        #expect(try await owner.members(of: mount).map(\.did) == [carolDID])
    }

    @Test func anEncryptedShareToAPlainDriveWarnsAndWorks() async throws {
        guard TestMode.encrypted else { return }
        let mount = try await sharedPhotos()
        #expect(try await owner.memberWarnings([bobDID], for: mount) == [.unprotected(bobDID)])
        #expect(try await owner.memberWarnings([carolDID], for: mount) == [])
        try await owner.addMembers([bobDID], to: mount)
        _ = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))
        #expect(try await contents(bob, "/photos/a.txt") == "aaa")
        #expect(try await owner.members(of: mount).first?.protected == false)
    }

    @Test func someoneWithoutASharingKeyCantJoinAnEncryptedShare() async throws {
        guard TestMode.encrypted else { return }
        let mount = try await sharedPhotos()
        let dave = pds.addAccount("dave")
        await #expect(throws: SharingError.noSharingKey(dave)) { try await owner.memberWarnings([dave], for: mount) }
        await #expect(throws: SharingError.noSharingKey(dave)) { try await owner.addMembers([dave], to: mount) }
    }

    @Test func aMemberRecordFromTheWrongSenderIsRefused() async throws {
        guard TestMode.encrypted else { return }
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        let space = mount.record.mount!.space
        // The PDS puts in a record of its own: a keyring of its choosing, wrapped for Bob.
        let bobsKey = try #require(
            try await SharingKeyRecord.fetch(bobDID, resolver: pds.resolver, transport: pds).flatMap(\.key))
        let forged = try MemberKeys.record(
            keyring: Keyring(DriveKey()), for: bobDID, key: bobsKey,
            from: SharingKeyPair(protected: true), space: space)
        pds.insertRawRecord(rkey: bobDID, collection: Lexicon.member, space: space, forged.anyValue)
        await #expect(throws: (any Error).self) { _ = try await bob.add(ShareLinkAddress(space: space)) }
    }

    @Test func membersAndTheLinkAreIndependent() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        let link = try await owner.turnLinkOn(mount)
        try await owner.turnLinkOff(mount)
        _ = try await bob.add(ShareLinkAddress(space: link.space))
        #expect(try await contents(bob, "/photos/a.txt") == "aaa", "still a member")
        try await owner.removeMembers([bobDID], from: mount)
        let again = try await owner.turnLinkOn(mount)
        _ = try await JoinedDrive.open(again, access: pds.access(as: nil))
        #expect(try await owner.members(of: mount).isEmpty)
    }

    @Test func publishesSharingKeys() async throws {
        let published = try #require(
            try await SharingKeyRecord.fetch(carolDID, resolver: pds.resolver, transport: pds))
        #expect(published.protected)
        let bobs = try #require(try await SharingKeyRecord.fetch(bobDID, resolver: pds.resolver, transport: pds))
        #expect(!bobs.protected)
        // Stable: ensuring it again changes nothing.
        try await carol.ensureSharingKey()
        #expect(try await SharingKeyRecord.fetch(carolDID, resolver: pds.resolver, transport: pds) == published)
    }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncEvent] = []
    func add(_ event: SyncEvent) { lock.withLock { events.append(event) } }
    var all: [SyncEvent] { lock.withLock { events } }
}

extension JSONValue {
    /// As Foundation JSON, for `FakePDS.insertRawRecord`.
    var anyValue: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(serialized()))) as? [String: Any] ?? [:]
    }
}

/// Verification codes for sharing keys (#30).
@Suite struct VerificationTests {
    let pds = FakePDS()
    let alice: JoinedDrive
    let bob: JoinedDrive
    let bobDID: String

    init() async throws {
        bobDID = pds.addAccount("bob")
        let home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        alice = JoinedDrive(home: home, access: pds.access())
        let bobs = pds.unopened("bob's", account: bobDID)
        _ = try await bobs.create(encrypted: true)
        bob = JoinedDrive(home: bobs, access: pds.access(as: bobDID))
        try await alice.ensureSharingKey()
        try await bob.ensureSharingKey()
    }

    @Test func bothSidesGetTheSameCode() async throws {
        let (mine, theirs) = try await alice.verificationCode(with: bobDID)
        let (bobs, _) = try await bob.verificationCode(with: FakePDS.defaultDID)
        #expect(mine == bobs)
        #expect(mine.split(separator: " ").count == 4 && mine.filter(\.isNumber).count == 16)
        #expect(try await !alice.isVerified(bobDID, key: theirs))
        try await alice.markVerified(bobDID, key: theirs)
        #expect(try await alice.isVerified(bobDID, key: theirs))
        // Every device of Alice's sees it: it's in her drive.
        let other = JoinedDrive(home: pds.device("other", keyring: alice.keyring), access: pds.access())
        #expect(try await other.verifiedKeys()[bobDID] == theirs.publicKey.data)
    }

    @Test func aSwappedKeyIsCaughtBeforeAnyKeyringIsWrapped() async throws {
        guard TestMode.encrypted else { return }
        let photos = try await alice.createFolder(named: "photos", in: nil)
        let mount = try await alice.share(photos)
        let (_, theirs) = try await alice.verificationCode(with: bobDID)
        try await alice.markVerified(bobDID, key: theirs)

        // Bob's PDS publishes a key of its own.
        let swapped = SharingKeyPair(protected: true)
        try await pds.client(as: bobDID).putPublicRecord(
            repo: bobDID, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey,
            record: try JSONValue(encoding: SharingKeyRecord(publicKey: swapped.publicKey, protected: true)))
        let warnings = try await alice.memberWarnings([bobDID], for: mount)
        #expect(warnings.contains { if case .keyChanged(bobDID, _, _) = $0 { true } else { false } })
        await #expect(throws: SharingError.keyChanged(bobDID)) { try await alice.addMembers([bobDID], to: mount) }
        #expect(pds.keys(in: Lexicon.member, space: mount.record.mount!.space).isEmpty, "nothing wrapped for it")
        #expect(
            try await !alice.isVerified(
                bobDID, key: SharingKeyRecord.fetch(bobDID, resolver: pds.resolver, transport: pds)))
    }

    @Test func rotatingTheSharingKeyPublishesANewOne() async throws {
        let before = try #require(try await SharingKeyRecord.fetch(bobDID, resolver: pds.resolver, transport: pds))
        try await bob.rotateSharingKey()
        let after = try #require(try await SharingKeyRecord.fetch(bobDID, resolver: pds.resolver, transport: pds))
        #expect(before.publicKey != after.publicKey)
    }
}

/// Fixes from the review of #42: each test is one finding.
@Suite struct SharingReviewTests {
    let pds = FakePDS()
    let owner: JoinedDrive
    let bob: JoinedDrive
    let bobDID: String

    init() async throws {
        bobDID = pds.addAccount("bob")
        let home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        owner = JoinedDrive(home: home, access: pds.access())
        let bobs = pds.unopened("bob's", account: bobDID)
        _ = try await bobs.create(encrypted: true)
        bob = JoinedDrive(home: bobs, access: pds.access(as: bobDID))
        try await owner.ensureSharingKey()
        try await bob.ensureSharingKey()
    }

    func file(_ contents: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("f.txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func sharedPhotos() async throws -> Node {
        let photos = try await owner.createFolder(named: "photos", in: nil)
        _ = try await owner.upload(try file("aaa"), as: "a.txt", in: photos.id)
        return try await owner.share(photos)
    }

    func contents(_ drive: JoinedDrive, _ path: String) async throws -> String? {
        guard let node = try? await drive.tree().locate(DrivePath(path)) else { return nil }
        var data = Data()
        try await drive.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func thePDSCantTurnAnEncryptedShareIntoAPlainOne() async throws {
        guard TestMode.encrypted else { return }
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        let space = mount.record.mount!.space
        pds.insertRawRecord(
            rkey: Lexicon.settingsKey, collection: Lexicon.settings, space: space,
            ["$type": Lexicon.settings, "retentionDays": 30, "generation": 9])

        // A fresh device of the owner's won't write to it in the clear.
        let fresh = JoinedDrive(home: pds.device("fresh", keyring: owner.keyring), access: pds.access())
        let snapshot = try await fresh.update(nil)
        #expect(snapshot.mounts[mount.id]?.problem == .keys(SharingError.downgraded.description))
        await #expect(throws: (any Error).self) {
            _ = try await fresh.upload(try file("secret"), as: "secret-name.txt", in: mount.id)
        }
        // Nor does someone with the link take it for plain.
        await #expect(throws: SharingError.downgraded) {
            _ = try await JoinedDrive.open(link, access: pds.access(as: nil))
        }
    }

    @Test func removingAMemberKeepsTheLinkWorking() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        try await owner.addMembers([bobDID], to: mount)
        try await owner.removeMembers([bobDID], from: mount)
        #expect(try await owner.link(of: mount) == link, "the same link, key and all")
        _ = try await owner.upload(try file("new"), as: "after.txt", in: mount.id)
        let opened = try await JoinedDrive.open(link, access: pds.access(as: nil))
        let tree = try await opened.drive.tree()
        let after = try #require(try tree.locate(DrivePath("/after.txt")), "readable with the link after rotation")
        var data = Data()
        try await opened.drive.read(after) { data.append($0) }
        #expect(String(decoding: data, as: UTF8.self) == "new")
        // And turning it on again isn't stuck.
        #expect(try await owner.turnLinkOn(mount) == link)
    }

    @Test func turningEncryptionOffAfterSharingConverts() async throws {
        guard TestMode.encrypted else { return }
        _ = try await sharedPhotos()
        try await owner.endSharing()
        try await owner.home.disableEncryption()
        let status = try await owner.home.convert()
        #expect(status.pending == 0)
        #expect(try await contents(owner, "/photos/a.txt") == "aaa")
    }

    @Test func deletingYourShareStopsSharingIt() async throws {
        let mount = try await sharedPhotos()
        let link = try await owner.turnLinkOn(mount)
        try await owner.addMembers([bobDID], to: mount)
        let tree = try await owner.tree()
        try await owner.delete(tree.descendants(of: mount.id) + [tree.nodes[mount.id]!])
        let space = mount.record.mount!.space
        #expect(pds.policy(of: space)?.policy == .personal)
        #expect(pds.policy(of: space)?.members == [])
        await #expect(throws: (any Error).self) { _ = try await JoinedDrive.open(link, access: pds.access(as: nil)) }
    }

    /// Unsharing takes it away from those who had it; sharing again gives them a new share.
    @Test func unsharingTakesItAwayAndItCanBeSharedAgain() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        _ = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))
        #expect(try await contents(bob, "/photos/a.txt") == "aaa")

        try await owner.unshare(mount)
        #expect(try await contents(bob, "/photos/a.txt") == nil)
        let folder = try #require(try await owner.tree().locate(DrivePath("/photos")))
        let again = try await owner.share(folder)
        try await owner.addMembers([bobDID], to: again)
        _ = try await bob.add(ShareLinkAddress(space: again.record.mount!.space))
        #expect(try await contents(bob, "/photos/a.txt") == "aaa")
    }

    /// A shared file opened from its link is the file, in the recipient's drive too.
    @Test func aSharedFileOpensAsTheFile() async throws {
        let notes = try await owner.upload(try file("hello"), as: "notes.txt", in: nil)
        let mount = try await owner.share(notes)
        let link = try await owner.turnLinkOn(mount)
        let added = try await bob.add(link)
        #expect(added.name == "notes.txt")
        let tree = try await bob.tree()
        let node = try #require(try tree.locate(DrivePath("/notes.txt")))
        #expect(node.isMount && !node.isFolder && tree.children(of: node.id).isEmpty)
        #expect(try await contents(bob, "/notes.txt") == "hello")
        // Read-only: new contents are refused.
        await #expect(throws: (any Error).self) {
            _ = try await bob.upload(try file("mine"), as: "notes.txt", in: nil, replacing: node)
        }
    }

    /// Downloading from a link: a shared file comes down as the file, a folder as a folder.
    @Test func downloadingALinkKeepsAFileAFile() async throws {
        let notes = try await owner.upload(try file("hello"), as: "notes.txt", in: nil)
        let fileLink = try await owner.turnLinkOn(try await owner.share(notes))
        let photos = try await owner.createFolder(named: "photos", in: nil)
        _ = try await owner.upload(try file("aaa"), as: "a.txt", in: photos.id)
        let trip = try await owner.createFolder(named: "trip", in: photos.id)
        _ = try await owner.upload(try file("bbb"), as: "b.txt", in: trip.id)
        let folderLink = try await owner.turnLinkOn(try await owner.share(photos))
        let here = try temporaryDirectory()

        let downloaded = try await JoinedDrive.open(fileLink, access: pds.access(as: nil)).download(into: here)
        #expect(downloaded.lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: downloaded, encoding: .utf8) == "hello")

        var written: [String] = []
        let folder = try await JoinedDrive.open(folderLink, access: pds.access(as: nil)).download(into: here) {
            path, _ in written.append(path.description)
        }
        #expect(try String(contentsOf: folder.appendingPathComponent("trip/b.txt"), encoding: .utf8) == "bbb")
        #expect(written.sorted() == ["/photos/a.txt", "/photos/trip/b.txt"])
    }

    /// A shared file syncs as a file: its owner's edits go to the share, a recipient's stay put.
    @Test func aSharedFileSyncsAsAFile() async throws {
        let notes = try await owner.upload(try file("hello"), as: "notes.txt", in: nil)
        let mount = try await owner.share(notes)
        try await owner.addMembers([bobDID], to: mount)
        _ = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))

        let mine = try temporaryDirectory().appendingPathComponent("mine")
        let theirs = try temporaryDirectory().appendingPathComponent("theirs")
        let ownerSync = try FolderSync(folder: mine, drive: owner, settle: 0)
        let bobSync = try FolderSync(folder: theirs, drive: bob, settle: 0)
        try await ownerSync.sync()
        try await bobSync.sync()
        for folder in [mine, theirs] {
            var isFolder: ObjCBool = true
            let path = folder.appendingPathComponent("notes.txt").path
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue)
        }

        try Data("edited".utf8).write(to: mine.appendingPathComponent("notes.txt"))
        try await ownerSync.sync()
        #expect(try await contents(owner, "/notes.txt") == "edited")
        #expect(try await owner.tree().nodes[mount.id]?.isMount == true, "still shared")
        try await bobSync.sync()
        #expect(try String(contentsOf: theirs.appendingPathComponent("notes.txt"), encoding: .utf8) == "edited")

        try Data("bob's".utf8).write(to: theirs.appendingPathComponent("notes.txt"))
        try await bobSync.sync()
        #expect(try await contents(owner, "/notes.txt") == "edited", "read-only for bob")
        #expect(try String(contentsOf: theirs.appendingPathComponent("notes.txt"), encoding: .utf8) == "edited")
        let copy = try #require(
            try FileManager.default.contentsOfDirectory(atPath: theirs.path).first { $0.hasPrefix("notes (conflicted") }
        )
        #expect(try await contents(bob, "/\(copy)") == "bob's", "kept in Bob's own drive")

        // It can move around Bob's drive, but keeps its name.
        let fm = FileManager.default
        try fm.createDirectory(at: theirs.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.moveItem(
            at: theirs.appendingPathComponent("notes.txt"), to: theirs.appendingPathComponent("docs/renamed.txt"))
        try await bobSync.sync()
        try await bobSync.sync()
        #expect(try await contents(bob, "/docs/notes.txt") == "edited")
        #expect(fm.fileExists(atPath: theirs.appendingPathComponent("docs/notes.txt").path))
        #expect(!fm.fileExists(atPath: theirs.appendingPathComponent("docs/renamed.txt").path))
    }

    @Test func aShareWhoseMountCantBeReadKeepsItsFilesInSync() async throws {
        let mount = try await sharedPhotos()
        let folder = try temporaryDirectory().appendingPathComponent("drive")
        do {
            let sync = try FolderSync(folder: folder, drive: owner, settle: 0)
            try await sync.sync()
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))
            // The mount's own record stops reading (written by a newer version, say).
            pds.insertRawRecord(rkey: mount.id, ["$type": Lexicon.node, "kind": "something-new", "name": 7])
            try await sync.sync()
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos/a.txt").path))
    }

    @Test func aRecipientWhoVerifiedTheOwnerRefusesAnotherKey() async throws {
        guard TestMode.encrypted else { return }
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        let (_, ownersKey) = try await bob.verificationCode(with: FakePDS.defaultDID)
        try await bob.markVerified(FakePDS.defaultDID, key: ownersKey)
        // The owner's PDS publishes another key, and wraps a keyring of its own for Bob with it.
        let impostor = SharingKeyPair(protected: true)
        try await pds.client().putPublicRecord(
            repo: FakePDS.defaultDID, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey,
            record: try JSONValue(encoding: SharingKeyRecord(publicKey: impostor.publicKey, protected: true)))
        let bobsKey = try #require(
            try await SharingKeyRecord.fetch(bobDID, resolver: pds.resolver, transport: pds)?.key)
        let space = mount.record.mount!.space
        let forged = try MemberKeys.record(
            keyring: Keyring(DriveKey()), for: bobDID, key: bobsKey, from: impostor, space: space)
        pds.insertRawRecord(rkey: bobDID, collection: Lexicon.member, space: space, forged.anyValue)
        await #expect(throws: (any Error).self) { _ = try await bob.add(ShareLinkAddress(space: space)) }
    }

    // MARK: Names

    /// A share you received has its owner's name: you can't rename it (the CLI, sync and Finder
    /// all go through `move`), but it can go anywhere in your drive. When its owner renames it,
    /// it's renamed for you.
    @Test func aReceivedShareKeepsItsOwnersName() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        let added = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))
        #expect(added.name == "photos")

        await #expect(throws: SharingError.notYoursToRename("photos")) {
            _ = try await bob.move(added, to: nil, as: "mine now")
        }
        let folder = try await bob.createFolder(named: "from others", in: nil)
        let moved = try await bob.move(added, to: folder.id, as: "photos")
        #expect(moved.name == "photos")
        #expect(try await contents(bob, "/from others/photos/a.txt") == "aaa")

        // The owner renames it: so does everyone who has it.
        let owners = try #require(try await owner.tree().locate(DrivePath("/photos")))
        _ = try await owner.move(owners, to: nil, as: "pictures")
        #expect(try await contents(bob, "/from others/pictures/a.txt") == "aaa")
        #expect((try? await bob.tree().locate(DrivePath("/from others/photos"))) == nil)
    }

    @Test func aReceivedFileKeepsItsOwnersNameToo() async throws {
        let notes = try await owner.upload(try file("notes"), as: "notes.txt", in: nil)
        let mount = try await owner.share(notes)
        try await owner.addMembers([bobDID], to: mount)
        _ = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))
        let received = try #require(try await bob.tree().locate(DrivePath("/notes.txt")))
        await #expect(throws: SharingError.notYoursToRename("notes.txt")) {
            _ = try await bob.move(received, to: nil, as: "mine.txt")
        }

        let owners = try #require(try await owner.tree().locate(DrivePath("/notes.txt")))
        _ = try await owner.move(owners, to: nil, as: "minutes.txt")
        #expect(try await contents(owner, "/minutes.txt") == "notes")
        #expect(try await contents(bob, "/minutes.txt") == "notes")
        #expect((try? await bob.tree().locate(DrivePath("/notes.txt"))) == nil)
    }

    /// Named by its owner, a share can clash with something of yours: it's numbered.
    @Test func aReceivedShareWhoseNameIsTakenIsNumbered() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        _ = try await bob.add(ShareLinkAddress(space: mount.record.mount!.space))
        let mine = try await bob.createFolder(named: "pictures", in: nil)
        _ = mine
        let owners = try #require(try await owner.tree().locate(DrivePath("/photos")))
        _ = try await owner.move(owners, to: nil, as: "pictures")

        let tree = try await bob.tree()
        #expect(Set(tree.children(of: nil).map(\.name)) == ["pictures", "pictures (2)"])
        let shared = try #require(try tree.locate(DrivePath("/pictures (2)")))
        #expect(shared.isMount)
        let moved = try await bob.move(shared, to: nil, as: "pictures (2)")
        #expect(moved.isMount, "its name as shown is fine")
    }
}

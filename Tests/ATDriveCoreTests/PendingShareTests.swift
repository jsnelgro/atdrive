import Foundation
import Testing

@testable import ATDriveCore

/// Pending shares (#68): sharing with someone leaves an invite in their inbox, and the share waits
/// for them to accept or decline it. The owner (`did:plc:test`, its drive in the test mode), Bob
/// (a plain drive) and Carol (an encrypted one).
@Suite struct PendingShareTests {
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
        for drive in [owner, bob, carol] {
            try await drive.ensureSharingKey()
            try await drive.ensureInbox()
        }
    }

    func file(_ contents: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("f.txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// `/photos` with `a.txt`, shared.
    func sharedPhotos() async throws -> Node {
        let photos = try await owner.createFolder(named: "photos", in: nil)
        _ = try await owner.upload(try file("aaa"), as: "a.txt", in: photos.id)
        return try await owner.share(photos)
    }

    func contents(_ drive: JoinedDrive, _ path: String) async throws -> String? {
        let tree = try await drive.tree()
        guard let node = try? tree.locate(DrivePath(path)) else { return nil }
        var data = Data()
        try await drive.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func theInboxIsOnlyItsOwnersToRead() async throws {
        let inbox = XRPCClient.inbox(of: bobDID)
        #expect(pds.policy(of: inbox)?.policy == .members(publicRead: false, publicWrite: true))
        #expect(pds.policy(of: inbox)?.members == [])
        try await bob.ensureInbox()  // already there: fine
        let theirs = try await pds.access(as: carolDID).credentials(for: inbox)
        await #expect(throws: (any Error).self) { _ = try await theirs.client.listWriters(space: inbox) }
    }

    @Test func sharingWithSomeoneLeavesThemAPendingShare() async throws {
        #expect(try await bob.pendingShares().isEmpty)
        let mount = try await sharedPhotos()
        let failures = try await owner.addMembers([bobDID, carolDID], to: mount)
        #expect(failures.isEmpty)

        for recipient in [bob, carol] {
            let pending = try await recipient.pendingShares()
            #expect(pending.count == 1)
            let share = try #require(pending.first)
            #expect(share.name == "photos" && !share.isFile && share.owner == FakePDS.defaultDID)
            #expect(share.mode == (TestMode.encrypted ? .encrypted : .plain))
            #expect(share.problem == nil)

            let added = try await recipient.accept(share)
            #expect(added.isMount && added.name == "photos")
            #expect(try await contents(recipient, "/photos/a.txt") == "aaa")
            #expect(try await recipient.pendingShares().isEmpty, "in the drive now")
        }
    }

    @Test func aSharedFileIsPendingAsAFile() async throws {
        let notes = try await owner.upload(try file("notes"), as: "notes.txt", in: nil)
        let mount = try await owner.share(notes)
        try await owner.addMembers([bobDID], to: mount)
        let share = try #require(try await bob.pendingShares().first)
        #expect(share.name == "notes.txt" && share.isFile)
        _ = try await bob.accept(share)
        #expect(try await contents(bob, "/notes.txt") == "notes")
    }

    @Test func aDeclinedShareStaysDeclinedOnEveryDevice() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        let share = try #require(try await bob.pendingShares().first)
        try await bob.decline(share)
        try await bob.decline(share)  // twice is fine
        #expect(try await bob.pendingShares().isEmpty)

        let bobsLaptop = JoinedDrive(
            home: pds.device("bob's laptop", account: bobDID, mode: .plain), access: pds.access(as: bobDID))
        #expect(try await bobsLaptop.pendingShares().isEmpty)
        // Still shared with him: its link works.
        let added = try await bob.add(share.link)
        #expect(added.name == "photos")
    }

    /// Taken off it, or it stops being shared: it isn't pending any more, and its invite goes.
    @Test func aShareTakenBackIsntPending() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID, carolDID], to: mount)
        try await owner.removeMembers([bobDID], from: mount)
        #expect(try await bob.pendingShares().isEmpty)
        #expect(pds.keys(in: Lexicon.invite, space: XRPCClient.inbox(of: bobDID), did: FakePDS.defaultDID).isEmpty)
        #expect(try await carol.pendingShares().count == 1)

        try await owner.unshare(mount)
        #expect(try await carol.pendingShares().isEmpty)
        #expect(pds.keys(in: Lexicon.invite, space: XRPCClient.inbox(of: carolDID), did: FakePDS.defaultDID).isEmpty)
    }

    /// An invite is only a pointer: one naming someone else's share, or one this account can't
    /// open, gives nothing away and adds nothing.
    @Test func anInviteToSomeoneElsesShareIsIgnored() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([carolDID], to: mount)
        // Carol tells Bob about the owner's share, which isn't hers (or his) to have.
        let carols = XRPCClient(service: URL(string: "https://pds.test")!, transport: pds.as(carolDID))
        try await carols.putSpaceRecord(
            space: XRPCClient.inbox(of: bobDID), repo: carolDID, collection: Lexicon.invite, rkey: "x",
            record: InviteRecord(space: mount.record.mount!.space))
        #expect(try await bob.pendingShares().isEmpty)
    }

    @Test func noInboxYetMeansNothingPendingAndMakesOne() async throws {
        let daveDID = pds.addAccount("dave")
        let daves = pds.device("dave's", account: daveDID, mode: .plain)
        _ = try await daves.create(encrypted: false)
        let dave = JoinedDrive(home: daves, access: pds.access(as: daveDID))
        #expect(try await dave.pendingShares().isEmpty)
        #expect(pds.exists(XRPCClient.inbox(of: daveDID)))
    }

    /// Several shares, newest first; one already in the drive (from its link) isn't pending.
    @Test func severalPendingSharesNewestFirst() async throws {
        let first = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: first)
        let notes = try await owner.upload(try file("notes"), as: "notes.txt", in: nil)
        let second = try await owner.share(notes)
        try await owner.addMembers([bobDID], to: second)
        #expect(try await bob.pendingShares().map(\.name) == ["notes.txt", "photos"])

        _ = try await bob.add(ShareLinkAddress(space: first.record.mount!.space))
        #expect(try await bob.pendingShares().map(\.name) == ["notes.txt"])
    }

    @Test func invitesDontShowInTheSpacesView() {
        #expect(!SpaceData.isShown(XRPCClient.inbox(of: bobDID)))
    }

    @Test func resetTakesTheInboxAndInvitesAway() async throws {
        let mount = try await sharedPhotos()
        try await owner.addMembers([bobDID], to: mount)
        _ = try await AccountReset.run(client: owner.client, owner: FakePDS.defaultDID)
        #expect(!pds.exists(XRPCClient.inbox(of: FakePDS.defaultDID)))
        #expect(pds.keys(in: Lexicon.invite, space: XRPCClient.inbox(of: bobDID), did: FakePDS.defaultDID).isEmpty)
    }
}

import Foundation
import Testing

@testable import ATDriveCore

/// `share` and `unshare` (#20): moving a file or folder into a space of its own, mounted where it
/// was. Runs on a plain and an encrypted drive.
@Suite struct ShareTests {
    let pds = FakePDS()
    let home: Drive
    let joined: JoinedDrive

    init() async throws {
        home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        joined = JoinedDrive(home: home, access: pds.access())
    }

    func file(_ contents: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("f.txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// `/photos/2026/trip/a.jpg`, `/photos/2026/b.jpg`, `/photos/c.jpg`, and `/notes.txt`.
    func populate() async throws -> (photos: Node, notes: Node) {
        let photos = try await joined.createFolder(named: "photos", in: nil)
        let year = try await joined.createFolder(named: "2026", in: photos.id)
        let trip = try await joined.createFolder(named: "trip", in: year.id)
        _ = try await joined.upload(try file("a, a long one"), as: "a.jpg", in: trip.id)
        _ = try await joined.upload(try file("b"), as: "b.jpg", in: year.id)
        _ = try await joined.upload(try file("c c c"), as: "c.jpg", in: photos.id)
        let notes = try await joined.upload(try file("notes!"), as: "notes.txt", in: nil)
        return (photos, notes)
    }

    /// Every path in the drive, with each file's contents.
    func listing() async throws -> [String: String] {
        let tree = try await joined.tree()
        var result: [String: String] = [:]
        for node in tree.nodes.values {
            var data = Data()
            if !node.isFolder { try await joined.read(node) { data.append($0) } }
            result[tree.path(of: node).description] = node.isFolder ? "/" : String(decoding: data, as: UTF8.self)
        }
        return result
    }

    @Test func sharingAFolderLeavesTheDriveLookingTheSame() async throws {
        let (photos, _) = try await populate()
        let before = try await listing()
        pds.resetCounts()

        let mount = try await joined.share(photos)
        #expect(mount.isMount && mount.name == "photos")
        #expect(pds.uploads == 0, "the chunks are reused: nothing is uploaded")
        #expect(try await listing() == before)

        let info = try #require(mount.record.mount)
        #expect(pds.policy(of: info.space)?.policy == .members(publicRead: false))
        #expect(pds.policy(of: info.space)?.members == [])
        #expect(XRPCClient.spaceParts(info.space)?.key.count == 26)
        #expect((info.keyring != nil) == TestMode.encrypted)

        // The originals are gone from the home drive, kept in its history, and not in the trash.
        let snapshot = try await home.update(nil)
        #expect(snapshot.tree.nodes[photos.id] == nil)
        #expect(snapshot.history.versions(of: photos.id).last?.record.change == .shared)
        #expect(snapshot.trash().isEmpty)
    }

    /// A shared file is still the file: same place, name and contents, not a folder holding it.
    @Test func sharingAFile() async throws {
        let (_, notes) = try await populate()
        let before = try await listing()
        let mount = try await joined.share(notes)
        #expect(mount.name == "notes.txt" && mount.isMount && !mount.isFolder)
        #expect(try await listing() == before)
        let space = try #require(mount.record.mount?.space)
        let settings = try await Drive(client: home.client, owner: home.owner, space: space).settingsRecord()
        #expect(settings != nil)
    }

    /// Editing, renaming and moving a shared file: the contents go to its space, the rest to the
    /// mount, and it stays one shared file.
    @Test func aSharedFileCanBeEditedRenamedAndMoved() async throws {
        let (photos, notes) = try await populate()
        var shared = try await joined.share(notes)
        let space = try #require(shared.record.mount?.space)

        shared = try await joined.upload(try file("new notes"), as: "notes.txt", in: nil, replacing: shared)
        #expect(shared.isMount && !shared.isFolder)
        #expect(try await listing()["/notes.txt"] == "new notes")
        let inShare = try await joined.update(nil).sharedFile(of: shared.id)
        #expect(inShare?.record.size == 9, "the new contents are in the share's space")

        shared = try await joined.move(shared, to: photos.id, as: "renamed.txt")
        let listing = try await listing()
        #expect(listing["/photos/renamed.txt"] == "new notes")
        #expect(listing["/notes.txt"] == nil)
        let tree = try await joined.tree()
        let node = try #require(try tree.locate(DrivePath("/photos/renamed.txt")))
        #expect(node.isMount && node.record.mount?.space == space)
        #expect(tree.children(of: node.id).isEmpty)
    }

    @Test func aPlainShareFromAnEncryptedDriveUploadsAgain() async throws {
        guard TestMode.encrypted else { return }
        let (photos, _) = try await populate()
        let before = try await listing()
        pds.resetCounts()
        let mount = try await joined.share(photos, plain: true)
        #expect(pds.uploads > 0)
        #expect(mount.record.mount?.keyring == nil)
        #expect(try await listing() == before)
        #expect(try await joined.update(nil).mounts[mount.id]?.mode == .plain)
    }

    @Test func anInterruptedShareFinishesWhenRunAgain() async throws {
        let (photos, _) = try await populate()
        let before = try await listing()
        // Cut off partway through copying.
        pds.failingAfter["com.atproto.space.applyWrites"] = 4
        await #expect(throws: (any Error).self) { try await joined.share(photos) }
        pds.failingAfter = [:]
        // Meanwhile the folder is still there (maybe twice); it never disappears.
        let during = try await joined.tree()
        #expect(try during.locate(DrivePath("/photos/c.jpg")) != nil)

        let mount = try await joined.share(try #require(try during.locate(DrivePath("/photos"))))
        #expect(try await listing() == before)
        let spaces = try await home.client.listSpaces(type: Lexicon.driveSpace)
        #expect(spaces.count == 2, "the home drive and one share")
        #expect(mount.name == "photos")
    }

    @Test func refusesWhatCantBeShared() async throws {
        let (photos, _) = try await populate()
        let mount = try await joined.share(photos)
        await #expect(throws: SharingError.alreadyShared("/photos")) { try await joined.share(mount) }
        let inside = try #require(try await joined.tree().locate(DrivePath("/photos/c.jpg")))
        await #expect(throws: SharingError.self) { try await joined.share(inside) }
    }

    /// Unsharing makes it an ordinary folder again, where it was, and deletes the share's space.
    @Test func unsharingPutsTheFolderBack() async throws {
        let (photos, _) = try await populate()
        let before = try await listing()
        let mount = try await joined.share(photos)
        let bob = pds.addAccount("bob")
        let space = try #require(mount.record.mount?.space)
        try await home.client.putMembers(space, [SpaceMember(did: bob)])

        try await joined.unshare(mount)
        #expect(try await listing() == before)
        #expect(try await home.client.listSpaces(type: Lexicon.driveSpace).count == 1, "the share's space is gone")
        let folder = try #require(try await joined.tree().locate(DrivePath("/photos")))
        #expect(!folder.isMount && folder.isFolder)
        _ = try await joined.upload(try file("new"), as: "new.jpg", in: folder.id)
        #expect(try await listing()["/photos/new.jpg"] == "new")
    }

    @Test func unsharingAFilePutsTheFileBack() async throws {
        let (_, notes) = try await populate()
        let before = try await listing()
        let mount = try await joined.share(notes)
        try await joined.unshare(mount)
        #expect(try await listing() == before)
        let file = try #require(try await joined.tree().locate(DrivePath("/notes.txt")))
        #expect(!file.isMount && !file.isFolder)
    }

    /// Cut off partway through copying back, unsharing again finishes it, with nothing doubled.
    @Test func anInterruptedUnshareFinishesWhenRunAgain() async throws {
        let (photos, _) = try await populate()
        let before = try await listing()
        let mount = try await joined.share(photos)
        pds.failingAfter["com.atproto.space.applyWrites"] = 3
        await #expect(throws: (any Error).self) { try await joined.unshare(mount) }
        pds.failingAfter = [:]
        try await joined.unshare(mount)
        #expect(try await listing() == before)
    }

    @Test func endingSharingPutsSharesBackInTheDrive() async throws {
        let (photos, notes) = try await populate()
        let before = try await listing()
        _ = try await joined.share(photos)
        _ = try await joined.share(notes)
        let spaces = try await home.client.listSpaces(type: Lexicon.driveSpace)
        #expect(spaces.count == 3)

        let ended = try await joined.endSharing()
        #expect(Set(ended) == ["/photos", "/notes.txt"])
        let tree = try await joined.tree()
        #expect(tree.nodes.values.allSatisfy { !$0.isMount })
        #expect(try await listing() == before, "a shared file comes back as the file")
        #expect(try await home.client.listSpaces(type: Lexicon.driveSpace) == [home.space])
    }
}

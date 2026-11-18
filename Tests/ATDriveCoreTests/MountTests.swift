import Foundation
import Testing

@testable import ATDriveCore

/// A drive made of several spaces (`JoinedDrive`): the home drive and spaces of the owner's
/// mounted in it. Runs on a plain and an encrypted home drive, like the drive-logic suites; some
/// tests mount a space of the other mode too.
@Suite struct MountTests {
    let pds = FakePDS()
    let home: Drive
    let joined: JoinedDrive
    let folder: URL

    init() async throws {
        home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        joined = JoinedDrive(home: home, access: pds.access())
        folder = try temporaryDirectory().appendingPathComponent("drive")
    }

    /// A space of the owner's, mounted at `/name`: encrypted unless `plain` (always plain on a plain
    /// home drive, which can't hold its keys).
    @discardableResult
    func mountSpace(_ name: String, plain: Bool = !TestMode.encrypted) async throws -> (Drive, Node) {
        let space = try await Drive.createSpace(
            client: home.client, owner: home.owner, key: newShareKey(), encrypted: !plain, policy: .personal,
            transfers: .fixed(8))
        let mount = try await joined.mount(MountInfo(space: space.space, keyring: space.keyring), named: name, in: nil)
        return (space, mount)
    }

    func file(_ contents: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("f.txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func contents(_ node: Node) async throws -> String {
        var data = Data()
        try await joined.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func pathsCrossMounts() async throws {
        let (space, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        let docs = try await joined.createFolder(named: "docs", in: mount.id)
        let note = try await joined.upload(try file("hello from a shared space"), as: "note.txt", in: docs.id)
        #expect(NodeID.split(note.id).mount == mount.id)

        let tree = try await joined.tree()
        let found = try #require(try tree.locate(DrivePath("/shared/docs/note.txt")))
        #expect(found.id == note.id)
        #expect(try await contents(found) == "hello from a shared space")
        // It's in the mounted space, not the home drive.
        #expect(try await space.tree().locate(DrivePath("/docs/note.txt"))?.id == NodeID.split(note.id).rkey)
        #expect(try await home.tree().nodes.values.allSatisfy { $0.name != "note.txt" })
        // Renaming within a space is a move there.
        let renamed = try await joined.move(found, to: docs.id, as: "renamed.txt")
        #expect(renamed.id == note.id)
        #expect(try await joined.tree().locate(DrivePath("/shared/docs/renamed.txt")) != nil)
    }

    @Test func movesBetweenSpacesCopyThenDelete() async throws {
        let (_, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        let folder = try await joined.createFolder(named: "trip", in: nil)
        let photo = try await joined.upload(try file("a photo, so to speak"), as: "photo.jpg", in: folder.id)
        _ = try await joined.update(nil)
        pds.resetCounts()

        let moved = try await joined.move(folder, to: mount.id, as: "trip")
        #expect(NodeID.split(moved.id).mount == mount.id, "a new ID, in the mounted space")
        #expect(pds.uploads == 0, "same mode: the chunks are reused")
        var tree = try await joined.tree()
        let there = try #require(try tree.locate(DrivePath("/shared/trip/photo.jpg")))
        #expect(try await contents(there) == "a photo, so to speak")
        #expect(tree.nodes[folder.id] == nil && tree.nodes[photo.id] == nil)

        // And back out again.
        let back = try await joined.move(there, to: nil, as: "photo.jpg")
        #expect(NodeID.split(back.id).mount == nil)
        tree = try await joined.tree()
        #expect(try await contents(try #require(try tree.locate(DrivePath("/photo.jpg")))) == "a photo, so to speak")
        #expect(try tree.find(DrivePath("/shared/trip/photo.jpg")) == .missing)
    }

    @Test func movesBetweenEncryptedAndPlainSpacesTransferAgain() async throws {
        guard TestMode.encrypted else { return }  // a plain home drive mounts plain spaces only
        let (plainSpace, mount) = try await mountSpace("open", plain: true)
        _ = try await joined.update(nil)
        let secret = try await joined.upload(try file("now readable by the PDS"), as: "s.txt", in: nil)
        _ = try await joined.update(nil)
        pds.resetCounts()
        let moved = try await joined.move(secret, to: mount.id, as: "s.txt")
        #expect(pds.uploads > 0, "decrypted and uploaded again, as the target stores it")
        #expect(try await contents(moved) == "now readable by the PDS")
        let stored = try #require(try await plainSpace.tree().locate(DrivePath("/s.txt")))
        #expect(stored.record.chunks?.allSatisfy { !$0.isEncrypted } == true)
    }

    @Test func aPlainDriveCantHoldAnEncryptedSpacesKeys() async throws {
        guard !TestMode.encrypted else { return }
        let space = try await Drive.createSpace(
            client: home.client, owner: home.owner, key: newShareKey(), encrypted: true, policy: .personal)
        await #expect(throws: SharingError.keyringWouldBeReadable) {
            try await joined.mount(MountInfo(space: space.space, keyring: space.keyring), named: "x", in: nil)
        }
    }

    @Test func deletingAMountLeavesItsSpace() async throws {
        let (space, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        let inside = try await joined.upload(try file("still here"), as: "a.txt", in: mount.id)
        let tree = try await joined.tree()
        try await joined.delete(tree.descendants(of: mount.id) + [tree.nodes[mount.id]!])
        #expect(try await joined.tree().nodes[mount.id] == nil)
        #expect(try await space.tree().nodes[NodeID.split(inside.id).rkey] != nil)
        #expect(pds.exists(space.space))
    }

    @Test func mountsDontNest() async throws {
        let (_, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        let other = try await Drive.createSpace(
            client: home.client, owner: home.owner, key: newShareKey(), encrypted: TestMode.encrypted, policy: .personal
        )
        await #expect(throws: SharingError.self) {
            try await joined.mount(MountInfo(space: other.space, keyring: other.keyring), named: "in", in: mount.id)
        }
        let (_, second) = try await mountSpace("second")
        _ = try await joined.update(nil)
        await #expect(throws: SharingError.self) { try await joined.move(second, to: mount.id, as: "second") }
    }

    @Test func aWriteNeverCreatesAMissingSpace() async throws {
        let (space, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        try await home.client.deleteSpace(space.space)
        let snapshot = try await joined.update(nil)
        #expect(snapshot.mounts[mount.id]?.problem != nil)
        await #expect(throws: (any Error).self) { try await joined.createFolder(named: "x", in: mount.id) }
        #expect(!pds.exists(space.space))
    }

    @Test func eachSpaceFollowsItsOwnChangeFeed() async throws {
        let (space, mount) = try await mountSpace("shared")
        var snapshot = try await joined.update(nil)
        _ = try await joined.upload(try file("x"), as: "x.txt", in: mount.id)
        snapshot = try await joined.update(snapshot)
        pds.resetCounts()
        // Nothing changed: one request per space.
        snapshot = try await joined.update(snapshot)
        #expect(pds.count("com.atproto.space.listRepoOps") == 2)
        #expect(pds.count("com.atproto.space.listRecords") <= 1)  // the mounted space's settings
        // A change in the mounted space alone.
        _ = try await space.createFolder(named: "made elsewhere", in: nil)
        snapshot = try await joined.update(snapshot)
        #expect(try snapshot.tree.locate(DrivePath("/shared/made elsewhere")) != nil)
    }

    // MARK: Sync

    func sync() throws -> FolderSync { try FolderSync(folder: folder, drive: joined, settle: 0) }

    func local(_ path: String) -> String? {
        FileManager.default.contents(atPath: folder.appendingPathComponent(path).path).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    @Test func syncsAcrossMounts() async throws {
        let (space, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        _ = try await joined.upload(try file("from the drive"), as: "in.txt", in: mount.id)
        let sync = try sync()
        try await sync.sync()
        #expect(local("shared/in.txt") == "from the drive")

        // A local file in the mount goes to its space.
        try Data("from here".utf8).write(to: folder.appendingPathComponent("shared/out.txt"))
        try await sync.sync()
        #expect(try await space.tree().locate(DrivePath("/out.txt")) != nil)

        // A change made in the space alone comes down.
        _ = try await space.createFolder(named: "new", in: nil)
        try await sync.sync()
        var isFolder: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("shared/new").path, isDirectory: &isFolder))
        #expect(isFolder.boolValue)
    }

    @Test func aMountThatCantBeReadKeepsItsFilesHere() async throws {
        let (space, mount) = try await mountSpace("shared")
        _ = try await joined.update(nil)
        _ = try await joined.upload(try file("keep me"), as: "keep.txt", in: mount.id)
        do {
            let sync = try sync()
            try await sync.sync()
            #expect(local("shared/keep.txt") == "keep me")

            // The space stops answering (its records gone with it, as far as this device can tell).
            try await home.client.deleteSpace(space.space)
            try await sync.sync()
            #expect(local("shared/keep.txt") == "keep me", "held, never taken for deleted")
        }
        // Even from a fresh start with nothing saved about the mount.
        try await FolderSync(folder: folder, drive: JoinedDrive(home: home, access: pds.access()), settle: 0).sync()
        #expect(local("shared/keep.txt") == "keep me")
    }
}

import Foundation
import Testing

@testable import ATDriveCore

/// A read-only folder in a synced folder (a share someone else owns): the drive's version always
/// wins. What's changed here is put back at the next sync; what was edited or added here is first
/// kept at the top of the drive, so nobody's work is lost.
@Suite struct ReadOnlyFolderSyncTests {
    let pds = FakePDS()
    let owner: JoinedDrive
    let bob: JoinedDrive
    let folder: URL
    let events = Events()
    let sync: FolderSync

    init() async throws {
        let bobDID = pds.addAccount("bob")
        let home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        owner = JoinedDrive(home: home, access: pds.access())
        let bobs = pds.device("bob's", account: bobDID, mode: .plain)
        _ = try await bobs.create(encrypted: false)
        bob = JoinedDrive(home: bobs, access: pds.access(as: bobDID))
        for drive in [owner, bob] { try await drive.ensureSharingKey() }

        // The owner's `/photos`, with `a.txt` and `trip/b.txt`, opened by Bob from its link.
        let photos = try await owner.createFolder(named: "photos", in: nil)
        _ = try await owner.upload(try Self.file("aaa"), as: "a.txt", in: photos.id)
        let trip = try await owner.createFolder(named: "trip", in: photos.id)
        _ = try await owner.upload(try Self.file("bbb"), as: "b.txt", in: trip.id)
        let mount = try await owner.share(photos)
        _ = try await bob.add(try await owner.turnLinkOn(mount))

        folder = try temporaryDirectory().appendingPathComponent("bob")
        let events = events
        sync = try FolderSync(folder: folder, drive: bob, settle: 0) { events.add($0) }
        try await sync.sync()
    }

    static func file(_ contents: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("f.txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func write(_ path: String, _ contents: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func files(_ path: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(path).path).sorted()
    }

    func onDrive(_ drive: JoinedDrive, _ path: String) async throws -> String? {
        let tree = try await drive.tree()
        guard let node = try? tree.locate(DrivePath(path)) else { return nil }
        var data = Data()
        try await drive.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Two passes: the second must find nothing left to do.
    func settle() async throws {
        try await sync.sync()
        let before = events.all.count
        try await sync.sync()
        let again = events.all.dropFirst(before).map(\.description)
        #expect(again.isEmpty, "settled: \(again)")
    }

    @Test func anEditIsKeptAtTheTopAndTheOriginalComesBack() async throws {
        try write("photos/a.txt", "bob was here")
        try await settle()

        #expect(read("photos/a.txt") == "aaa", "the drive's version")
        #expect(try await onDrive(owner, "/photos/a.txt") == "aaa", "never uploaded")
        let copy = try #require(try files().first { $0.hasPrefix("a (conflicted copy") })
        #expect(read(copy) == "bob was here")
        #expect(try await onDrive(bob, "/\(copy)") == "bob was here", "in Bob's own drive")
        #expect(events.all.contains { $0.kind == .keptOutside && $0.path == "/photos/a.txt" })
    }

    @Test func theOwnersNewVersionArrivesOverAnEditHere() async throws {
        try write("photos/a.txt", "bob was here")
        let a = try #require(try await owner.tree().locate(DrivePath("/photos/a.txt")))
        _ = try await owner.upload(
            try Self.file("the owner's new version"), as: "a.txt", in: a.record.parent, replacing: a)
        try await settle()

        #expect(read("photos/a.txt") == "the owner's new version")
        let copy = try #require(try files().first { $0.hasPrefix("a (conflicted copy") })
        #expect(read(copy) == "bob was here")
    }

    @Test func aDeletionIsPutBack() async throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent("photos/trip"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("photos/a.txt"))
        try await settle()

        #expect(read("photos/a.txt") == "aaa")
        #expect(read("photos/trip/b.txt") == "bbb")
        #expect(try await onDrive(owner, "/photos/trip/b.txt") == "bbb", "never deleted")
        #expect(events.all.contains { $0.kind == .undone })
    }

    @Test func movesAndRenamesArePutBack() async throws {
        let fm = FileManager.default
        try fm.moveItem(
            at: folder.appendingPathComponent("photos/a.txt"), to: folder.appendingPathComponent("photos/renamed.txt"))
        try fm.moveItem(
            at: folder.appendingPathComponent("photos/trip/b.txt"), to: folder.appendingPathComponent("b.txt"))
        try await settle()

        #expect(try files("photos") == ["a.txt", "trip"])
        #expect(read("photos/trip/b.txt") == "bbb")
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("b.txt").path))
        #expect(try await onDrive(owner, "/photos/a.txt") == "aaa")
    }

    @Test func somethingNewIsKeptAtTheTop() async throws {
        try write("photos/new.txt", "new")
        try write("photos/trip/album/c.txt", "ccc")
        try await settle()

        #expect(try files("photos") == ["a.txt", "trip"])
        #expect(try files("photos/trip") == ["b.txt"])
        #expect(read("new.txt") == "new")
        #expect(read("album/c.txt") == "ccc", "a new folder comes with what's in it")
        #expect(try await onDrive(bob, "/album/c.txt") == "ccc")
        #expect(try await onDrive(owner, "/photos/new.txt") == nil)
    }

    @Test func somethingOfYoursMovedInGoesBack() async throws {
        try write("mine.txt", "mine")
        try await sync.sync()
        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("mine.txt"), to: folder.appendingPathComponent("photos/mine.txt"))
        try await settle()

        #expect(read("mine.txt") == "mine")
        #expect(try files("photos") == ["a.txt", "trip"])
        #expect(try await onDrive(owner, "/photos/mine.txt") == nil)
    }
}

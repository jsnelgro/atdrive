import Foundation
import Testing

@testable import ATDriveCore

/// History and the trash across the joined drive (#11): what the Mac app's Trash window and
/// Finder's "Restore Previous Version…" use. Runs on a plain and an encrypted drive.
@Suite struct JoinedHistoryTests {
    let pds = FakePDS()
    let clock = TestClock(HistoryTests.start)
    let home: Drive
    let joined: JoinedDrive
    let directory: URL

    init() async throws {
        let clock = clock
        home = pds.device("here", tids: TIDSource(clockID: 1) { clock.now })
        _ = try await home.create(encrypted: TestMode.encrypted)
        joined = JoinedDrive(home: home, access: pds.access())
        directory = try temporaryDirectory()
    }

    func file(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// `/photos/2026/trip/a.jpg`, `/photos/2026/b.jpg`, `/photos/c.jpg`, and `/notes.txt`.
    @discardableResult
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
            result[tree.path(of: node).description] = node.isFolder ? "/" : try await contents(node)
        }
        return result
    }

    func contents(_ node: Node) async throws -> String {
        var data = Data()
        try await joined.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    func node(_ path: String) async throws -> Node {
        try #require(try await joined.tree().locate(DrivePath(path)))
    }

    /// Deletes what's at `path`, with everything in it, as Finder and `rm -r` do; a minute later
    /// than whatever came before.
    func delete(_ path: String) async throws {
        clock.advance(60)
        let tree = try await joined.tree()
        let node = try #require(try tree.locate(DrivePath(path)))
        try await joined.delete(tree.descendants(of: node.id) + [node])
    }

    // MARK: The trash

    @Test func theTrashHoldsWhatWasDeletedInTheDriveAndInSharesOfYours() async throws {
        let (photos, _) = try await populate()
        _ = try await joined.share(photos)
        let before = try await listing()

        try await delete("/notes.txt")
        try await delete("/photos/c.jpg")
        try await delete("/photos/2026")
        let snapshot = try await joined.update(nil)
        let trash = snapshot.trash(now: clock.now)
        let paths = trash.map(\.path.description)
        #expect(paths == ["/photos/2026", "/photos/c.jpg", "/notes.txt"], "newest first")
        #expect(trash[0].isFolder && trash[0].inside == 3, "trip, a.jpg and b.jpg went with it")
        #expect(trash[0].mount != nil && trash[2].mount == nil)
        #expect(trash[0].folder == DrivePath("/photos"))
        #expect(trash[1].size == 5 && trash[0].size == nil)

        let result = try await joined.restoreFromTrash(trash.map(\.id), in: snapshot)
        #expect(result.skipped.isEmpty)
        #expect(result.restored.count == 6)
        #expect(try await listing() == before)
        #expect(try await joined.update(nil).trash(now: clock.now).isEmpty)
    }

    /// A file deleted with its folder comes back with the folder above it, as `restore` does.
    @Test func restoringSomethingBringsBackTheFoldersItWasIn() async throws {
        try await populate()
        try await delete("/photos/2026/trip/a.jpg")
        try await delete("/photos/2026/trip")
        try await delete("/photos/2026")
        let snapshot = try await joined.update(nil)
        let item = try #require(snapshot.trash(now: clock.now).first { $0.name == "a.jpg" })
        #expect(item.path == DrivePath("/photos/2026/trip/a.jpg"))

        try await joined.restoreFromTrash([item.id], in: snapshot)
        let listing = try await listing()
        #expect(listing["/photos/2026/trip/a.jpg"] == "a, a long one")
        #expect(listing["/photos/2026/b.jpg"] == nil, "only the folders it was in come back")
    }

    // MARK: A file's versions

    @Test func aFilesVersionsAreItsContents() async throws {
        var notes = try await joined.upload(try file("one"), as: "notes.txt", in: nil)
        notes = try await joined.upload(try file("two!"), as: "notes.txt", in: nil, replacing: notes)
        notes = try await joined.upload(try file("three"), as: "notes.txt", in: nil, replacing: notes)
        notes = try await joined.move(notes, to: nil, as: "renamed.txt")

        var snapshot = try await joined.update(nil)
        var versions = snapshot.versions(of: notes.id)
        #expect(versions.map(\.size) == [5, 4, 3], "newest first; the rename isn't a version")
        #expect(versions.map(\.isCurrent) == [true, false, false])
        #expect(versions.allSatisfy { $0.available })
        #expect(versions.map(\.entry.change) == [.edited, .edited, .created])

        // Back to the first: under its name now, and as a new version.
        let result = try await joined.restoreContents(of: notes.id, from: versions[2].version, in: snapshot)
        #expect(result.restored.count == 1 && result.skipped.isEmpty)
        #expect(try await listing() == ["/renamed.txt": "one"])
        snapshot = try await joined.update(nil)
        versions = snapshot.versions(of: notes.id)
        #expect(versions.map(\.size) == [3, 5, 4, 3])
        #expect(versions.first?.entry.change == .restored && versions.first?.isCurrent == true)

        // Which can be undone the same way.
        try await joined.restoreContents(of: notes.id, from: versions[1].version, in: snapshot)
        #expect(try await listing()["/renamed.txt"] == "three")

        // Restoring the contents it has writes nothing.
        snapshot = try await joined.update(nil)
        let current = try #require(snapshot.versions(of: notes.id).first)
        let again = try await joined.restoreContents(of: notes.id, from: current.version, in: snapshot)
        #expect(again.restored.isEmpty && again.skipped.isEmpty)
    }

    /// A restore that only put a file back where it was isn't a version of its contents.
    @Test func restoringFromTheTrashIsntANewVersion() async throws {
        var notes = try await joined.upload(try file("one"), as: "notes.txt", in: nil)
        notes = try await joined.upload(try file("two!"), as: "notes.txt", in: nil, replacing: notes)
        try await joined.delete([notes])
        var snapshot = try await joined.update(nil)
        try await joined.restoreFromTrash([notes.id], in: snapshot)
        snapshot = try await joined.update(nil)
        #expect(snapshot.versions(of: notes.id).map(\.size) == [4, 3])
        #expect(snapshot.versions(of: notes.id).first?.isCurrent == true)
    }

    @Test func versionsOfFilesInASharedFolderAndOfASharedFile() async throws {
        let (photos, notes) = try await populate()
        let mount = try await joined.share(photos)
        var shared = try await joined.share(notes)

        // In a shared folder.
        var c = try await node("/photos/c.jpg")
        c = try await joined.upload(try file("new c"), as: "c.jpg", in: c.record.parent, replacing: c)
        var snapshot = try await joined.update(nil)
        #expect(snapshot.history(of: c.id)?.mount == mount.id)
        var versions = snapshot.versions(of: c.id)
        #expect(versions.count == 2)
        try await joined.restoreContents(of: c.id, from: versions[1].version, in: snapshot)
        #expect(try await listing()["/photos/c.jpg"] == "c c c")

        // A share of one file: the history of the file in its space.
        shared = try await joined.upload(try file("new notes"), as: "notes.txt", in: nil, replacing: shared)
        snapshot = try await joined.update(nil)
        versions = snapshot.versions(of: shared.id)
        #expect(versions.map(\.size) == [9, 6])
        try await joined.restoreContents(of: shared.id, from: versions[1].version, in: snapshot)
        #expect(try await listing()["/notes.txt"] == "notes!")
    }

    @Test func foldersAndTheSpacesFolderHaveNoVersions() async throws {
        let (photos, _) = try await populate()
        let snapshot = try await joined.update(nil)
        #expect(snapshot.versions(of: photos.id).isEmpty)
        #expect(snapshot.history(of: photos.id) != nil, "a folder has history")
        #expect(snapshot.history(of: SpacesFolder.id) == nil)
        #expect(snapshot.history(of: "nothing") == nil)
    }

    // MARK: A folder as it was

    @Test func aFolderGoesBackAsItWasAtAChange() async throws {
        let (photos, _) = try await populate()
        let mount = try await joined.share(photos)
        clock.advance(60)
        let b = try await node("/photos/2026/b.jpg")
        _ = try await joined.upload(try file("b2"), as: "b.jpg", in: b.record.parent, replacing: b)
        let year = try await node("/photos/2026")
        var snapshot = try await joined.update(nil)
        let latest = try #require(snapshot.changes(in: year.id).first)
        #expect(latest.path == DrivePath("/photos/2026/b.jpg"), "paths are in the joined drive")
        #expect(latest.change == .edited)
        #expect(snapshot.history(of: mount.id) == nil, "a shared folder's history is what's in it")
        let before = try await listing()

        try await delete("/photos/2026/trip")
        let c = try await node("/photos/c.jpg")
        _ = try await joined.upload(try file("changed"), as: "c.jpg", in: c.record.parent, replacing: c)
        _ = try await joined.upload(try file("new"), as: "new.jpg", in: year.id)

        snapshot = try await joined.update(nil)
        let result = try await joined.restore(year.id, asOf: latest.date, in: snapshot)
        #expect(result.skipped.isEmpty)
        var expected = before
        expected["/photos/2026/new.jpg"] = "new"  // added since: it stays
        expected["/photos/c.jpg"] = "changed"  // not in the folder restored
        #expect(try await listing() == expected)
    }
}

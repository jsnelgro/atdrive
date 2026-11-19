import Foundation
import Testing

@testable import ATDriveCore

/// The Spaces folder (#28): other apps' spaces as a read-only folder at the top of the drive
/// (`SpacesFolder`), read like the rest of it, never written, and put back as the drive has it in
/// a synced folder.
@Suite struct SpacesFolderTests {
    let pds = FakePDS()
    let drive: JoinedDrive
    let board: String
    let me = FakePDS.defaultDID
    let folder: URL
    let events = Events()

    static let note = "/Spaces/Bulletin/home/note"

    init() async throws {
        let home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        drive = JoinedDrive(home: home, access: pds.access(), spaces: SpacesSettings())
        board = try await pds.client().createSpace(
            type: "my.bulletin.board", key: "home", policy: .members(publicRead: false))
        folder = try temporaryDirectory().appendingPathComponent("drive")
        try await put("n1", "first")
    }

    func put(_ rkey: String, _ text: String) async throws {
        try await pds.client().putSpaceRecord(
            space: board, repo: me, collection: "my.bulletin.note", rkey: rkey,
            record: JSONValue.object(["$type": .string("my.bulletin.note"), "text": .string(text)]))
    }

    func contents(_ path: String) async throws -> String? {
        let tree = try await drive.update(nil).tree
        guard let node = try? tree.locate(DrivePath(path)) else { return nil }
        var data = Data()
        try await drive.read(node) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    func sync() throws -> FolderSync {
        let events = events
        return try FolderSync(folder: folder, drive: drive, settle: 0) { events.add($0) }
    }

    func local(_ path: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Lets the next update read the spaces again rather than reuse what was just read.
    func later() async throws { try await Task.sleep(for: .seconds(JoinedDrive.spacesReuse + 0.1)) }

    @Test func itsFilesAreReadLikeAnyOthers() async throws {
        #expect(try await contents("\(Self.note)/n1.json")?.contains("\"text\": \"first\"") == true)
        let tree = try await drive.update(nil).tree
        #expect(tree.children(of: nil).map(\.name).contains("Spaces"))
        let file = try #require(try tree.locate(DrivePath("\(Self.note)/n1.json")))
        let saved = try temporaryDirectory().appendingPathComponent("n1.json")
        try await drive.download(file, to: saved)
        #expect(String(decoding: try Data(contentsOf: saved), as: UTF8.self).contains("first"))
    }

    @Test func nothingInItCanBeChanged() async throws {
        let snapshot = try await drive.update(nil)
        let tree = snapshot.tree
        let spaces = try #require(tree.nodes[SpacesFolder.id])
        let file = try #require(try tree.locate(DrivePath("\(Self.note)/n1.json")))
        let scratch = try temporaryDirectory().appendingPathComponent("x")
        try Data("x".utf8).write(to: scratch)
        let mine = try await drive.createFolder(named: "mine", in: nil)

        await #expect(throws: ATDriveError.inSpaces(path: "x")) {
            try await drive.createFolder(named: "x", in: spaces.id)
        }
        await #expect(throws: ATDriveError.self) { try await drive.upload(scratch, as: "x", in: file.record.parent) }
        await #expect(throws: ATDriveError.self) { try await drive.move(file, to: nil, as: "n1.json") }
        await #expect(throws: ATDriveError.self) { try await drive.move(spaces, to: mine.id, as: "Spaces") }
        await #expect(throws: ATDriveError.self) { try await drive.move(mine, to: spaces.id, as: "mine") }
        await #expect(throws: ATDriveError.self) { try await drive.delete([file]) }
        await #expect(throws: ATDriveError.self) { try await drive.delete([spaces]) }
    }

    @Test func aFolderOfYoursKeepsItsNameAndSpacesIsNumbered() async throws {
        _ = try await drive.createFolder(named: "Spaces", in: nil)
        let tree = try await drive.update(nil).tree
        #expect(tree.nodes[SpacesFolder.id]?.name == "Spaces (2)")
        #expect(try tree.locate(DrivePath("/Spaces (2)/Bulletin/home/note/n1.json")) != nil)
        #expect(try tree.locate(DrivePath("/Spaces"))?.id != SpacesFolder.id)
    }

    @Test func renamingItIsAChange() async throws {
        let before = try await drive.update(nil)
        try await later()
        drive.showSpaces(SpacesSettings(folder: "Other"))
        let after = try await drive.update(before)
        #expect(after.tree.nodes[SpacesFolder.id]?.name == "Other")
        #expect(after.anchor != before.anchor)
        // What Finder's enumerators are told: the folder changed.
        #expect(after.tree.changes(since: before.tree).updated.map(\.id).contains(SpacesFolder.id))
    }

    @Test func foldersAreAsNewAsWhatsInThem() async throws {
        try await pds.client().putSpaceRecord(
            space: board, repo: me, collection: "my.bulletin.note", rkey: "n2",
            record: JSONValue.object(["text": .string("dated"), "createdAt": .string("2026-11-02T08:00:00.000Z")]))
        let tree = try await drive.update(nil).tree
        let dated = try #require(Timestamp.parse("2026-11-02T08:00:00.000Z"))
        for path in ["/Spaces", "/Spaces/Bulletin", "/Spaces/Bulletin/home", Self.note] {
            let folder = try #require(try tree.locate(DrivePath(path)))
            #expect(folder.record.createdDate.map { $0 >= dated } == true, "\(path)")
        }
        let file = try #require(try tree.locate(DrivePath("\(Self.note)/n2.json")))
        #expect(file.record.modifiedDate == dated)
    }

    @Test func offMeansNoFolder() async throws {
        drive.showSpaces(nil)
        let tree = try await drive.update(nil).tree
        #expect(tree.nodes[SpacesFolder.id] == nil)
        #expect(tree.nodes.keys.allSatisfy { !SpacesFolder.contains($0) })
    }

    @Test func aSyncedFolderShowsWhatsThereAndPutsBackWhatsChanged() async throws {
        let sync = try sync()
        try await sync.sync()
        let n1 = "Spaces/Bulletin/home/note/n1.json"
        #expect(local(n1)?.contains("first") == true)

        // Edited, added, deleted and renamed here: all put back, nothing written to any space.
        try Data("mine now".utf8).write(to: folder.appendingPathComponent(n1))
        try Data("new".utf8).write(to: folder.appendingPathComponent("Spaces/Bulletin/home/new.txt"))
        let fm = FileManager.default
        try fm.moveItem(
            at: folder.appendingPathComponent("Spaces"), to: folder.appendingPathComponent("Renamed"))
        pds.resetCounts()
        try await sync.sync()
        try await sync.sync()
        #expect(local(n1)?.contains("first") == true)
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("Renamed").path))
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("Spaces/Bulletin/home/new.txt").path))
        #expect(try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") } == ["Spaces"])
        #expect(pds.count("com.atproto.space.putRecord") == 0 && pds.count("com.atproto.space.applyWrites") == 0)
        #expect(events.all.contains { $0.kind == .undone })

        try fm.removeItem(at: folder.appendingPathComponent(n1))
        try await sync.sync()
        #expect(local(n1)?.contains("first") == true)
    }

    @Test func aSyncedFolderFollowsTheSpaces() async throws {
        let sync = try sync()
        try await sync.sync()
        try await put("n1", "second")
        try await put("n2", "another")
        try await later()
        try await sync.sync()
        #expect(local("Spaces/Bulletin/home/note/n1.json")?.contains("second") == true)
        #expect(local("Spaces/Bulletin/home/note/n2.json")?.contains("another") == true)

        // Turned off: its copies go.
        drive.showSpaces(nil)
        try await sync.sync()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Spaces").path))
    }

    @Test func spacesThatCantBeReadLeaveTheFolderAlone() async throws {
        let sync = try sync()
        try await sync.sync()
        // Can't be read now: what was read last time stays, here and in the drive's tree.
        try await later()
        pds.failing["com.atproto.space.listSpaces"] = 10  // past the client's retries
        try await sync.sync()
        #expect(local("Spaces/Bulletin/home/note/n1.json")?.contains("first") == true)
        #expect(events.all.contains { $0.description.contains("can't read your spaces") })
        let snapshot = try #require(drive.latestSnapshot)
        #expect(snapshot.spaces?.problem != nil)
        #expect(try snapshot.tree.locate(DrivePath("\(Self.note)/n1.json")) != nil)
    }

    @Test func spacesNeverReadAreUnreadableNotEmpty() async throws {
        // Like a share that can't be read: nothing that came from it is taken for deleted.
        let home = try await drive.home.update(nil)
        let snapshot = JoinedSnapshot(home: home, spaces: SpacesFolder(settings: SpacesSettings()))
        #expect(snapshot.tree.unreadable[SpacesFolder.id] != nil)
        let base = SyncBase([
            SpacesFolder.id: SyncState.Item(
                parent: nil, name: "Spaces", folder: true, sha256: nil,
                stat: FileStat(device: 1, inode: 1, size: 0, modified: 0, changed: 0)),
            "\(SpacesFolder.id)/r|x": SyncState.Item(
                parent: SpacesFolder.id, name: "a.json", folder: false, sha256: "00",
                stat: FileStat(device: 1, inode: 2, size: 1, modified: 0, changed: 0)),
        ])
        let view = RemoteView(snapshot.tree, base: base, held: snapshot.held)
        #expect(view.unknown.isSuperset(of: [SpacesFolder.id, "\(SpacesFolder.id)/r|x"]))
    }
}

import Foundation
import Testing

@testable import ATDriveCore

/// Two-way sync between a temporary folder and an in-memory drive. `other` is a second device
/// editing the same drive.
@Suite struct FolderSyncTests {
    let pds = FakePDS()
    let drive: Drive
    let other: Drive
    let folder: URL

    init() throws {
        let transport = pds
        func device() -> Drive {
            Drive(
                client: XRPCClient(service: URL(string: "https://pds.test")!, transport: transport),
                owner: "did:plc:test", chunkSize: 4)
        }
        drive = device()
        other = device()
        folder = try temporaryDirectory().appendingPathComponent("drive")
    }

    func open() throws -> FolderSync { try FolderSync(folder: folder, drive: drive, settle: 0) }

    // MARK: The folder

    func write(_ path: String, _ contents: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: folder.appendingPathComponent(path).path).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    func remove(_ path: String) throws { try FileManager.default.removeItem(at: folder.appendingPathComponent(path)) }

    func move(_ from: String, _ to: String) throws {
        try FileManager.default.moveItem(at: folder.appendingPathComponent(from), to: folder.appendingPathComponent(to))
    }

    /// Everything in the folder (folders end in `/`), except the sync's own state.
    func localFiles() throws -> [String] {
        var result: [String] = []
        func walk(_ relative: String) throws {
            let url = relative.isEmpty ? folder : folder.appendingPathComponent(relative)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where !(relative.isEmpty && name == ".atdrive") {
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                var isFolder: ObjCBool = false
                _ = FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(path).path, isDirectory: &isFolder)
                result.append(isFolder.boolValue ? path + "/" : path)
                if isFolder.boolValue { try walk(path) }
            }
        }
        try walk("")
        return result.sorted()
    }

    // MARK: The drive

    func driveFiles() async throws -> [String] {
        let tree = try await other.tree()
        return tree.nodes.values.map { node in
            let path = String(tree.path(of: node).description.dropFirst())
            return node.isFolder ? path + "/" : path
        }.sorted()
    }

    func driveContents(_ path: String) async throws -> String {
        let node = try #require(try await other.tree().locate(DrivePath(path)))
        var data = Data()
        try await other.read(node) { data += $0 }
        return String(decoding: data, as: UTF8.self)
    }

    /// Uploads from "another device", creating folders as needed.
    func put(_ path: String, _ contents: String) async throws {
        let tree = try await other.tree()
        let drivePath = DrivePath(path)
        var parent: String?
        for name in drivePath.parent.components {
            if let existing = tree.child(named: name, in: parent) {
                parent = existing.id
            } else {
                parent = try await other.createFolder(named: name, in: parent).id
            }
        }
        let scratch = try temporaryDirectory().appendingPathComponent("upload")
        try Data(contents.utf8).write(to: scratch)
        let existing = try tree.find(drivePath)
        if case .node(let node) = existing {
            try await other.upload(scratch, as: node.name, in: node.record.parent, replacing: node)
        } else {
            try await other.upload(scratch, as: drivePath.name!, in: parent)
        }
    }

    func node(_ path: String) async throws -> Node {
        try #require(try await other.tree().locate(DrivePath(path)))
    }

    /// The end state of every scenario: the folder matches the drive, contents included, and
    /// syncing again changes nothing.
    func expectSettled(_ sync: FolderSync, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let files = try localFiles()
        #expect(try await driveFiles() == files, sourceLocation: sourceLocation)
        for file in files where !file.hasSuffix("/") {
            #expect(try await driveContents("/" + file) == read(file), "\(file)", sourceLocation: sourceLocation)
        }
        let calls = pds.calls.count
        #expect(try await sync.sync().changes == 0, sourceLocation: sourceLocation)
        let writes = pds.calls[calls...].filter {
            !["com.atproto.space.getLatestCommit", "com.atproto.space.listRecords", "com.atproto.space.listRepoOps"]
                .contains($0)
        }
        #expect(writes.isEmpty, "\(writes)", sourceLocation: sourceLocation)
        #expect(try localFiles() == files, sourceLocation: sourceLocation)
    }

    // MARK: Basics

    @Test func firstSyncDownloadsTheDrive() async throws {
        try await put("/docs/a.txt", "alpha")
        try await put("/b.txt", "bravo")
        let sync = try open()
        let result = try await sync.sync()
        #expect(result.changes == 3)
        #expect(try localFiles() == ["b.txt", "docs/", "docs/a.txt"])
        #expect(read("docs/a.txt") == "alpha")

        let calls = pds.calls.count
        #expect(try await sync.sync().changes == 0)
        #expect(!pds.calls[calls...].contains("com.atproto.space.putRecord"))
        try await expectSettled(sync)
    }

    @Test func firstSyncUploadsTheFolder() async throws {
        try write("notes/today.txt", "todo")
        try write("empty folder/.keep", "")
        try write("top.txt", "hello")
        let sync = try open()
        try await sync.sync()
        #expect(
            try await driveFiles() == ["empty folder/", "empty folder/.keep", "notes/", "notes/today.txt", "top.txt"])
        #expect(try await driveContents("/notes/today.txt") == "todo")
        try await expectSettled(sync)
    }

    @Test func firstSyncMergesWhatsAlreadyThere() async throws {
        try await put("/shared/same.txt", "identical")
        try await put("/shared/different.txt", "the drive's")
        try write("shared/same.txt", "identical")
        try write("shared/different.txt", "this computer's")
        try write("shared/mine.txt", "only here")
        let calls = pds.calls.count
        let sync = try open()
        try await sync.sync()

        let files = try localFiles()
        #expect(try await driveFiles() == files)
        #expect(files.count == 5)
        #expect(read("shared/same.txt") == "identical")
        #expect(read("shared/different.txt") == "the drive's")
        let copy = try #require(files.first { $0.hasPrefix("shared/different (conflicted copy") })
        #expect(read(copy) == "this computer's")
        // The folder and the identical file were paired up, not uploaded again: only the copy
        // and mine.txt were.
        #expect(pds.calls[calls...].filter { $0 == "com.atproto.space.putRecord" }.count == 2)
        try await expectSettled(sync)
    }

    // MARK: Changes in the folder

    @Test func editsCreationsAndDeletionsGoUp() async throws {
        try write("a.txt", "one")
        try write("gone.txt", "bye")
        let sync = try open()
        try await sync.sync()
        let id = try await node("/a.txt").id

        try write("a.txt", "one, edited")
        try write("new/b.txt", "bee")
        try remove("gone.txt")
        try await sync.sync()

        #expect(try await driveFiles() == ["a.txt", "new/", "new/b.txt"])
        #expect(try await driveContents("/a.txt") == "one, edited")
        #expect(try await node("/a.txt").id == id)  // edited in place, not replaced
        try await expectSettled(sync)
    }

    @Test func renamingAFolderIsOneUpdate() async throws {
        try write("photos/1.jpg", "jpeg1")
        try write("photos/2019/2.jpg", "jpeg2")
        let sync = try open()
        try await sync.sync()
        let ids = try await (node("/photos/1.jpg").id, node("/photos/2019/2.jpg").id)

        try move("photos", "Pictures")
        let calls = pds.calls.count
        try await sync.sync()

        #expect(try await driveFiles() == ["Pictures/", "Pictures/1.jpg", "Pictures/2019/", "Pictures/2019/2.jpg"])
        #expect(try await (node("/Pictures/1.jpg").id, node("/Pictures/2019/2.jpg").id) == ids)
        let made = pds.calls[calls...]
        #expect(made.filter { $0 == "com.atproto.space.putRecord" }.count == 1)
        #expect(!made.contains("com.atproto.repo.uploadBlob"))
        try await expectSettled(sync)
    }

    @Test func movingAFileBetweenFoldersKeepsIt() async throws {
        try write("inbox/report.pdf", "pdf!")
        try write("archive/old.txt", "old")
        let sync = try open()
        try await sync.sync()
        let id = try await node("/inbox/report.pdf").id

        try move("inbox/report.pdf", "archive/report-2026.pdf")
        try await sync.sync()
        #expect(try await driveFiles() == ["archive/", "archive/old.txt", "archive/report-2026.pdf", "inbox/"])
        #expect(try await node("/archive/report-2026.pdf").id == id)
        try await expectSettled(sync)
    }

    @Test func copiedThenDeletedCountsAsAMove() async throws {
        try write("a/file.bin", "contents")
        let sync = try open()
        try await sync.sync()
        let id = try await node("/a/file.bin").id

        // A new inode with the same contents, like `mv` across disks.
        try write("b/file.bin", "contents")
        try remove("a/file.bin")
        try await sync.sync()
        #expect(try await node("/b/file.bin").id == id)
        try await expectSettled(sync)
    }

    // MARK: Changes on the drive

    @Test func changesFromElsewhereComeDown() async throws {
        try await put("/a.txt", "one")
        try await put("/folder/b.txt", "bee")
        try await put("/gone.txt", "bye")
        let sync = try open()
        try await sync.sync()

        try await put("/a.txt", "one, edited elsewhere")
        try await other.move(try await node("/folder"), to: nil, as: "renamed")
        try await other.delete([try await node("/gone.txt")])
        try await put("/renamed/c.txt", "sea")
        try await sync.sync()

        #expect(try localFiles() == ["a.txt", "renamed/", "renamed/b.txt", "renamed/c.txt"])
        #expect(read("a.txt") == "one, edited elsewhere")
        try await expectSettled(sync)
    }

    @Test func swappedNamesFromElsewhere() async throws {
        try await put("/a.txt", "was a")
        try await put("/b.txt", "was b")
        let sync = try open()
        try await sync.sync()

        let (a, b) = try await (node("/a.txt"), node("/b.txt"))
        try await other.move(a, to: nil, as: "tmp")
        try await other.move(b, to: nil, as: "a.txt")
        try await other.move(try await node("/tmp"), to: nil, as: "b.txt")
        try await sync.sync()

        #expect(try localFiles() == ["a.txt", "b.txt"])
        #expect(read("a.txt") == "was b")
        #expect(read("b.txt") == "was a")
        try await expectSettled(sync)
    }

    @Test func folderMovedIntoAFolderThatsNewHere() async throws {
        try await put("/stuff/x.txt", "x")
        let sync = try open()
        try await sync.sync()

        let archive = try await other.createFolder(named: "archive", in: nil)
        try await other.move(try await node("/stuff"), to: archive.id, as: "stuff")
        try await sync.sync()
        #expect(try localFiles() == ["archive/", "archive/stuff/", "archive/stuff/x.txt"])
        try await expectSettled(sync)
    }

    @Test func downloadsKeepTheFilesPermissions() async throws {
        try write("run.sh", "echo 1")
        let sync = try open()
        try await sync.sync()
        let path = folder.appendingPathComponent("run.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try await sync.sync()

        try await put("/run.sh", "echo 2, longer")
        try await sync.sync()
        #expect(read("run.sh") == "echo 2, longer")
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber) == 0o755)
        try await expectSettled(sync)
    }

    // MARK: Conflicts

    @Test func editedInBothPlacesKeepsBoth() async throws {
        try write("notes.txt", "v1")
        let log = Log()
        let sync = try FolderSync(folder: folder, drive: drive, settle: 0) { log.add($0) }
        try await sync.sync()

        try write("notes.txt", "v2 from here")
        try await put("/notes.txt", "v2 from elsewhere")
        try await sync.sync()
        let events = log.events

        let files = try localFiles()
        #expect(try await driveFiles() == files)
        #expect(files.count == 2)
        #expect(read("notes.txt") == "v2 from elsewhere")
        let copy = try #require(files.first { $0.hasPrefix("notes (conflicted copy") })
        #expect(read(copy) == "v2 from here")
        #expect(try await driveContents("/" + copy) == "v2 from here")
        #expect(events.contains { $0.kind == .conflict })
        try await expectSettled(sync)
    }

    @Test func deletedHereButEditedThereComesBack() async throws {
        try write("keep.txt", "v1")
        let sync = try open()
        try await sync.sync()

        try remove("keep.txt")
        try await put("/keep.txt", "v2, edited elsewhere")
        try await sync.sync()
        #expect(read("keep.txt") == "v2, edited elsewhere")
        #expect(try await driveFiles() == ["keep.txt"])
        try await expectSettled(sync)
    }

    @Test func deletedThereButEditedHereGoesBackUp() async throws {
        try write("keep.txt", "v1")
        let sync = try open()
        try await sync.sync()

        try await other.delete([try await node("/keep.txt")])
        try write("keep.txt", "v2, edited here")
        try await sync.sync()
        #expect(try await driveContents("/keep.txt") == "v2, edited here")
        #expect(try localFiles() == ["keep.txt"])
        try await expectSettled(sync)
    }

    @Test func folderDeletedThereKeepsWhatsNewInsideIt() async throws {
        try write("project/old.txt", "old")
        let sync = try open()
        try await sync.sync()

        let project = try await node("/project")
        try await other.delete([try await node("/project/old.txt"), project])
        try write("project/new.txt", "added while it was being deleted")
        try await sync.sync()

        #expect(try localFiles() == ["project/", "project/new.txt"])
        #expect(try await driveFiles() == ["project/", "project/new.txt"])
        try await expectSettled(sync)
    }

    @Test func movedBothWaysTheDrivesMoveWins() async throws {
        try write("a.txt", "a")
        let sync = try open()
        try await sync.sync()

        try move("a.txt", "here.txt")
        try await other.move(try await node("/a.txt"), to: nil, as: "there.txt")
        try await sync.sync()
        #expect(try localFiles() == ["there.txt"])
        #expect(try await driveFiles() == ["there.txt"])
        try await expectSettled(sync)
    }

    @Test func foldersMovedIntoEachOther() async throws {
        try write("a/1", "1")
        try write("b/2", "2")
        let sync = try open()
        try await sync.sync()

        try move("a", "b/a")  // here: a into b
        try await other.move(try await node("/b"), to: try await node("/a").id, as: "b")  // there: b into a
        try await sync.sync()
        let files = try localFiles()
        #expect(try await driveFiles() == files)
        #expect(files.contains { $0.hasSuffix("/1") } && files.contains { $0.hasSuffix("/2") })
        try await expectSettled(sync)
    }

    @Test func sameNameTwiceOnTheDrive() async throws {
        try await put("/dup.txt", "first")
        let scratch = try temporaryDirectory().appendingPathComponent("x")
        try Data("second".utf8).write(to: scratch)
        try await other.upload(scratch, as: "dup.txt", in: nil)
        let sync = try open()
        try await sync.sync()

        let files = try localFiles()
        #expect(files.count == 2)
        #expect(try await driveFiles() == files)
        #expect(Set(files.map { read($0)! }) == ["first", "second"])
        try await expectSettled(sync)
    }

    // MARK: Safety

    @Test func ignoredFilesStayPut() async throws {
        try write(".DS_Store", "finder")
        try write("docs/.notes.txt.swp", "vim")
        try write("docs/notes.txt", "real")
        try await put("/Thumbs.db", "windows")
        let sync = try open()
        try await sync.sync()
        #expect(try await driveFiles() == ["Thumbs.db", "docs/", "docs/notes.txt"])
        #expect(try localFiles() == [".DS_Store", "docs/", "docs/.notes.txt.swp", "docs/notes.txt"])

        // A folder deleted elsewhere goes, clutter and all; ignored things on the drive stay.
        try await other.delete([try await node("/docs/notes.txt"), try await node("/docs")])
        try await sync.sync()
        #expect(try localFiles() == [".DS_Store"])
        #expect(try await driveFiles() == ["Thumbs.db"])
        #expect(try await sync.sync().changes == 0)
    }

    @Test func aFileEditedDuringItsDownloadIsNotOverwritten() async throws {
        try write("busy.txt", "v1")
        let sync = try open()
        try await sync.sync()

        try await put("/busy.txt", "v2 from elsewhere")
        // Edited here after the folder was listed, while the drive's version downloads.
        let path = folder.appendingPathComponent("busy.txt")
        pds.onRequest = { method in
            if method == "com.atproto.space.getBlob" { try? Data("v2 from here!".utf8).write(to: path) }
        }
        try await sync.sync()
        pds.onRequest = nil
        #expect(read("busy.txt") == "v2 from here!")

        try await sync.sync()  // and next time, it's an ordinary conflict
        let files = try localFiles()
        #expect(files.count == 2)
        #expect(Set(files.map { read($0)! }) == ["v2 from elsewhere", "v2 from here!"])
        #expect(try await driveFiles() == files)
        try await expectSettled(sync)
    }

    @Test func refusesAnotherAccountsFolder() async throws {
        _ = try open()
        let stranger = Drive(
            client: XRPCClient(service: URL(string: "https://pds.test")!, transport: pds), owner: "did:plc:other")
        #expect(throws: SyncError.otherAccount(folder: folder.resolvingSymlinksInPath().path, owner: "did:plc:test")) {
            try FolderSync(folder: folder, drive: stranger)
        }
    }

    @Test func onlyOneSyncPerFolder() throws {
        let first = try open()
        #expect(throws: SyncError.self) { try open() }
        _ = first
    }

    @Test func stopsIfTheFolderOrItsStateDisappears() async throws {
        try write("a.txt", "a")
        let sync = try open()
        try await sync.sync()
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".atdrive"))
        await #expect(throws: SyncError.stateMissing(sync.root)) { try await sync.sync() }
        try FileManager.default.removeItem(at: folder)
        await #expect(throws: SyncError.folderMissing(sync.root)) { try await sync.sync() }
        #expect(try await driveFiles() == ["a.txt"])
    }

    // MARK: Can't see it isn't deleted

    /// A record as a newer version of ATDrive might write it: one this version can't decode.
    func newerFormat(_ name: String) -> [String: Any] {
        ["$type": Lexicon.node, "name": name, "kind": "package", "createdAt": "2026-11-09T00:00:00Z"]
    }

    @Test func anUnreadableFileIsLeftAloneOnBothSides() async throws {
        try write("a.txt", "mine")
        try write("b.txt", "bee")
        let log = Log()
        let sync = try FolderSync(folder: folder, drive: drive, settle: 0) { log.add($0) }
        try await sync.sync()
        let id = try await node("/a.txt").id

        pds.insertRawRecord(rkey: id, newerFormat("a.txt"))
        let cid = pds.cid(of: id)
        try await sync.sync()
        #expect(read("a.txt") == "mine")  // not taken for deleted on the drive

        try write("a.txt", "mine, edited")
        try await sync.sync()
        #expect(pds.cid(of: id) == cid)  // not written over
        try remove("a.txt")
        try await sync.sync()
        #expect(pds.cid(of: id) == cid)  // not deleted either

        // Said once, and everything else still syncs.
        #expect(log.events.filter { $0.kind == .unreadable }.map(\.path) == ["/a.txt"])
        try await put("/b.txt", "bee, edited elsewhere")
        try await sync.sync()
        #expect(read("b.txt") == "bee, edited elsewhere")
        #expect(try localFiles() == ["b.txt"])
    }

    @Test func whatChangedHereWhileUnreadableSyncsOnceItCanBeRead() async throws {
        try write("a.txt", "v1")
        let sync = try open()
        try await sync.sync()
        let original = try await node("/a.txt")

        pds.insertRawRecord(rkey: original.id, newerFormat("a.txt"))
        try write("a.txt", "v2 from here")
        try await sync.sync()
        #expect(read("a.txt") == "v2 from here")

        // Readable again, as it was: the edit here goes up, since its saved state was kept.
        try await other.restore(original)
        try await sync.sync()
        #expect(try await driveContents("/a.txt") == "v2 from here")
        #expect(try await node("/a.txt").id == original.id)
        try await expectSettled(sync)
    }

    @Test func whatsInAnUnreadableFolderStillSyncs() async throws {
        try write("docs/a.txt", "a")
        let sync = try open()
        try await sync.sync()
        let docs = try await node("/docs")
        let a = try await node("/docs/a.txt")

        pds.insertRawRecord(rkey: docs.id, newerFormat("docs"))
        let docsCID = pds.cid(of: docs.id)
        let scratch = try temporaryDirectory()
        try Data("a, edited elsewhere".utf8).write(to: scratch.appendingPathComponent("a"))
        try Data("new".utf8).write(to: scratch.appendingPathComponent("b"))
        try await other.upload(scratch.appendingPathComponent("a"), as: "a.txt", in: docs.id, replacing: a)
        try await other.upload(scratch.appendingPathComponent("b"), as: "b.txt", in: docs.id)
        try write("docs/c.txt", "from here")
        try await sync.sync()

        #expect(try localFiles() == ["docs/", "docs/a.txt", "docs/b.txt", "docs/c.txt"])
        #expect(read("docs/a.txt") == "a, edited elsewhere")
        #expect(read("docs/b.txt") == "new")
        let uploaded = try #require(try await other.tree().nodes.values.first { $0.name == "c.txt" })
        #expect(uploaded.record.parent == docs.id)
        #expect(pds.cid(of: docs.id) == docsCID)
        #expect(try await sync.sync().changes == 0)
    }

    @Test func aDriveThatsGoneStopsSync() async throws {
        try write("a.txt", "the only copy")
        let sync = try open()
        try await sync.sync()

        pds.wipe()
        await #expect(throws: SyncError.driveMissing(sync.root)) { try await sync.sync() }
        try write("b.txt", "new")
        await #expect(throws: SyncError.driveMissing(sync.root)) { try await sync.sync() }
        #expect(read("a.txt") == "the only copy")
        #expect(!pds.spaceExists)  // and not made again with only b.txt in it

        // A folder that never synced still creates the drive.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".atdrive"))
        let fresh = try open()
        try await fresh.sync()
        #expect(try await driveFiles() == ["a.txt", "b.txt"])
    }

    // MARK: Following the drive

    @Test func anIdlePassIsOneRequest() async throws {
        try write("a.txt", "a")
        let sync = try open()
        try await sync.sync()
        try await sync.sync()
        let calls = pds.calls.count
        try await sync.sync()
        #expect(Array(pds.calls[calls...]) == ["com.atproto.space.listRepoOps"])
    }

    @Test func changesFromElsewhereArriveWithoutListingEverything() async throws {
        try await put("/a.txt", "one")
        try await put("/docs/b.txt", "bee")
        let sync = try open()
        try await sync.sync()

        try await put("/a.txt", "one, edited")
        try await other.delete([try await node("/docs/b.txt")])
        try await put("/c.txt", "sea")
        let calls = pds.calls.count
        try await sync.sync()
        #expect(!pds.calls[calls...].contains("com.atproto.space.listRecords"))
        #expect(try localFiles() == ["a.txt", "c.txt", "docs/"])
        #expect(read("a.txt") == "one, edited")
        try await expectSettled(sync)
    }

    @Test func aGapInTheFeedFallsBackToAFullListing() async throws {
        try await put("/a.txt", "v1")
        let sync = try open()
        try await sync.sync()

        try await put("/a.txt", "v2")
        let compacted = try #require(pds.revision)
        try await put("/a.txt", "v3")
        pds.compactOps(through: compacted)
        let calls = pds.calls.count
        try await sync.sync()
        #expect(pds.calls[calls...].contains("com.atproto.space.listRecords"))
        #expect(read("a.txt") == "v3")
        try await expectSettled(sync)
    }

    @Test func theDriveIsSavedForTheNextRun() async throws {
        try write("a.txt", "a")
        var sync: FolderSync? = try open()
        try await sync!.sync()
        try await sync!.sync()
        let saved = folder.appendingPathComponent(".atdrive/drive.json").path
        #expect(FileManager.default.fileExists(atPath: saved))
        sync = nil

        // It matched the drive's commit, so it's checked again rather than listed on start.
        let reopened = try open()
        let calls = pds.calls.count
        #expect(try await reopened.sync().changes == 0)
        #expect(!pds.calls[calls...].contains("com.atproto.space.listRecords"))
        try await expectSettled(reopened)
    }

    @Test func filesStillBeingWrittenWait() async throws {
        try write("big.iso", "partial")
        let sync = try FolderSync(folder: folder, drive: drive, settle: 60)
        let result = try await sync.sync()
        #expect(result.waiting)
        #expect(try await driveFiles() == [])
    }

    // MARK: Interruptions

    @Test func anInterruptedUploadPicksUpWhereItLeftOff() async throws {
        for index in 1...4 { try write("f\(index).txt", "file \(index)") }
        let sync = try open()
        pds.failing["com.atproto.space.putRecord"] = 1  // the first file's record fails
        await #expect(throws: XRPCError.self) { try await sync.sync() }
        try await sync.sync()
        #expect(try await driveFiles() == ["f1.txt", "f2.txt", "f3.txt", "f4.txt"])
        #expect(try await sync.sync().changes == 0)
        try await expectSettled(sync)
    }

    @Test func anInterruptedConflictDoesntMakeTwoCopies() async throws {
        try write("notes.txt", "v1")
        let sync = try open()
        try await sync.sync()

        try write("notes.txt", "v2 from here")
        try await put("/notes.txt", "v2 from elsewhere")
        pds.corruptDownloads = true  // the copy goes up, then the download fails
        try await sync.sync()
        pds.corruptDownloads = false
        try await sync.sync()

        let files = try localFiles()
        #expect(files.count == 2)
        #expect(try await driveFiles() == files)
        #expect(read("notes.txt") == "v2 from elsewhere")
        try await expectSettled(sync)
    }

    @Test func recoversFromAKilledMove() async throws {
        try write("a.txt", "a")
        let sync = try open()
        try await sync.sync()
        // As if a pass was killed halfway through moving a.txt.
        let staging = folder.appendingPathComponent(".atdrive/staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try move("a.txt", ".atdrive/staging/1")
        try JSONEncoder().encode(["1": "a.txt"]).write(to: folder.appendingPathComponent(".atdrive/staging.json"))
        try await sync.sync()
        #expect(try localFiles() == ["a.txt"])
        #expect(try await driveFiles() == ["a.txt"])
        try await expectSettled(sync)
    }
}

@Suite struct SyncNamingTests {
    @Test func conflictNames() {
        let date = Date(timeIntervalSince1970: 1_794_212_281)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: date)
        #expect(
            ConflictName.make(for: "report.pdf", at: date) { _ in false } == "report (conflicted copy \(stamp)).pdf")
        #expect(ConflictName.make(for: "Makefile", at: date) { _ in false } == "Makefile (conflicted copy \(stamp))")
        let taken: Set = ["a (conflicted copy \(stamp)).txt", "a (conflicted copy \(stamp) 2).txt"]
        #expect(
            ConflictName.make(for: "a.txt", at: date) { taken.contains($0) } == "a (conflicted copy \(stamp) 3).txt")
        let long = String(repeating: "x", count: 250) + ".txt"
        #expect(ConflictName.make(for: long, at: date) { _ in false }.utf8.count <= 255)
    }

    @Test func ignoredNames() {
        for name in [
            ".DS_Store", "Thumbs.db", ".notes.txt.swp", ".x.swo", ".~lock.report.odt#", "~$report.docx",
            "#draft.txt#", ".#draft.txt", "photo.jpg.atdrive-partial",
        ] {
            #expect(SyncIgnore.isIgnored(name, atTop: false), "\(name)")
        }
        for name in [".gitignore", ".swp", "notes.swp", "~notes", "#hashtag", ".atdrive", "draft.txt#"] {
            #expect(!SyncIgnore.isIgnored(name, atTop: false), "\(name)")
        }
        #expect(SyncIgnore.isIgnored(".atdrive", atTop: true))
    }
}

/// Collects events from a sync (for tests).
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [SyncEvent] = []
    func add(_ event: SyncEvent) { lock.withLock { collected.append(event) } }
    var events: [SyncEvent] { lock.withLock { collected } }
}

#if os(Linux)
    @Suite struct FolderWatcherTests {
        @Test func wakesUpWhenSomethingChanges() async throws {
            let folder = try temporaryDirectory()
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let watcher = FolderWatcher()
            watcher.watch([folder.path, folder.appendingPathComponent("sub").path])
            #expect(watcher.isWatching)

            var mark = watcher.mark()
            #expect(await !watcher.wait(since: mark, timeout: .milliseconds(300)))

            mark = watcher.mark()
            try Data("hi".utf8).write(to: folder.appendingPathComponent("sub/new.txt"))
            #expect(await watcher.wait(since: mark, timeout: .seconds(5), quiet: .milliseconds(100)))

            // A folder that goes away loses its watch; one that appears gets one when listed.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("sub"))
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("later"), withIntermediateDirectories: true)
            watcher.watch([folder.path, folder.appendingPathComponent("later").path])
            try await Task.sleep(for: .milliseconds(200))
            mark = watcher.mark()
            try Data("hi".utf8).write(to: folder.appendingPathComponent("later/x"))
            #expect(await watcher.wait(since: mark, timeout: .seconds(5), quiet: .milliseconds(100)))
        }
    }
#endif

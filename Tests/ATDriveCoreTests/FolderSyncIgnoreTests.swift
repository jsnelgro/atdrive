import Foundation
import Testing

@testable import ATDriveCore

/// `atdrive sync` with ignore files: what they ignore is left alone on both sides.
extension FolderSyncTests {
    func open(ignore: IgnoreSettings, log: Log? = nil) throws -> FolderSync {
        try FolderSync(folder: folder, drive: drive, settle: 0, ignore: ignore) { log?.add($0) }
    }

    @Test func ignoredThingsArentUploaded() async throws {
        try write(".atdriveignore", "*.log\nbuild/\n")
        try write("a.txt", "a")
        try write("debug.log", "noise")
        try write("build/out.bin", "binary")
        try write("sub/deeper/trace.log", "noise")
        try write("sub/deeper/keep.txt", "keep")
        let sync = try open()
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore", "a.txt", "sub/", "sub/deeper/", "sub/deeper/keep.txt"])
        // And they're still here.
        #expect(read("debug.log") == "noise")
        #expect(read("build/out.bin") == "binary")
        #expect(try await sync.sync().changes == 0)
    }

    @Test func gitignoreCountsUnlessTurnedOff() async throws {
        try write(".gitignore", ".env\n")
        try write(".env", "SECRET=1")
        try write("notes.txt", "n")
        let sync = try open()
        try await sync.sync()
        #expect(try await driveFiles() == [".gitignore", "notes.txt"])
        sync.ignore = IgnoreSettings(respectGitignore: false)
        try await sync.sync()
        #expect(try await driveFiles() == [".env", ".gitignore", "notes.txt"])
    }

    @Test func atdriveignoreAlwaysCounts() async throws {
        try write(".atdriveignore", "*.tmp\n")
        try write("a.tmp", "t")
        let sync = try open(ignore: IgnoreSettings(respectGitignore: false))
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore"])
    }

    @Test func atdriveignoreCanBringBackWhatGitIgnores() async throws {
        try write(".gitignore", "*.secret\n")
        try write("project/.atdriveignore", "!keep.secret\n")
        try write("project/keep.secret", "k")
        try write("project/drop.secret", "d")
        let sync = try open()
        try await sync.sync()
        #expect(
            try await driveFiles() == [".gitignore", "project/", "project/.atdriveignore", "project/keep.secret"])
    }

    @Test func globalPatternsFromConfig() async throws {
        try write("node_modules/x/index.js", "js")
        try write("app/node_modules/y.js", "js")
        try write("app/main.swift", "code")
        try write("cache.tmp", "t")
        try write(".atdriveignore", "!cache.tmp\n")
        let sync = try open(ignore: IgnoreSettings(patterns: ["node_modules/", "*.tmp"]))
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore", "app/", "app/main.swift", "cache.tmp"])
    }

    @Test func ignoredThingsArentDownloaded() async throws {
        try write(".atdriveignore", "node_modules/\n*.log\n")
        let sync = try open()
        try await sync.sync()
        try await put("/node_modules/x.js", "from elsewhere")
        try await put("/app/run.log", "from elsewhere")
        try await put("/app/main.swift", "code")
        try await sync.sync()
        #expect(try localFiles() == [".atdriveignore", "app/", "app/main.swift"])
        // Nor deleted from the drive.
        #expect(try await driveFiles().contains("node_modules/x.js"))
        #expect(try await driveFiles().contains("app/run.log"))
    }

    @Test func somethingIgnoredLaterIsLeftAloneOnBothSides() async throws {
        try write("logs/a.log", "one")
        try write("notes.txt", "n")
        let sync = try open()
        try await sync.sync()
        #expect(try await driveFiles() == ["logs/", "logs/a.log", "notes.txt"])

        // Now ignored: deleting it here leaves the drive's copy, and changes there don't come here.
        try write(".atdriveignore", "logs/\n")
        try await sync.sync()
        try remove("logs")
        try await put("/logs/b.log", "two")
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore", "logs/", "logs/a.log", "logs/b.log", "notes.txt"])
        #expect(try localFiles() == [".atdriveignore", "notes.txt"])
    }

    @Test func somethingNoLongerIgnoredIsPairedUpAgain() async throws {
        try write(".atdriveignore", "logs/\n")
        try write("logs/a.log", "same")
        try write("logs/mine.log", "only here")
        let sync = try open()
        try await sync.sync()
        try await put("/logs/a.log", "same")
        try await put("/logs/theirs.log", "only there")

        try remove(".atdriveignore")
        try await sync.sync()
        let files = ["logs/", "logs/a.log", "logs/mine.log", "logs/theirs.log"]
        #expect(try localFiles() == files)
        #expect(try await driveFiles() == files)
        #expect(read("logs/theirs.log") == "only there")
        #expect(try await driveContents("/logs/mine.log") == "only here")
        try await expectSettled(sync)
    }

    @Test func aFolderDeletedElsewhereKeepsItsIgnoredFilesHere() async throws {
        try write(".atdriveignore", "*.log\n")
        try write("project/a.txt", "a")
        try write("project/debug.log", "local only")
        let log = Log()
        let sync = try open(ignore: IgnoreSettings(), log: log)
        try await sync.sync()
        let project = try await node("/project")
        try await other.delete([try await node("/project/a.txt"), project])

        try await sync.sync()
        #expect(try localFiles() == [".atdriveignore", "project/", "project/debug.log"])
        #expect(log.events.contains { $0.kind == .skipped && $0.path == "/project" })
        // It isn't put back on the drive…
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore"])
        // …unless something that isn't ignored goes in it.
        try write("project/new.txt", "new")
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore", "project/", "project/new.txt"])
    }

    @Test func ignoreFilesFromTheDriveApplyOnceTheyreHere() async throws {
        let sync = try open()
        try await sync.sync()
        try await put("/.atdriveignore", "*.cache\n")
        try await sync.sync()
        #expect(read(".atdriveignore") == "*.cache\n")
        try write("big.cache", "c")
        try await sync.sync()
        #expect(try await driveFiles() == [".atdriveignore"])
    }

    // MARK: Finding what's ignored (atdrive dev delete-ignored)

    @Test func findsWhatsIgnoredHere() throws {
        try write(".atdriveignore", "*.log\nbuild/\n")
        try write(".gitignore", ".env\n")
        try write("a.txt", "a")
        try write("x.log", "l")
        try write(".env", "SECRET=1")
        try write("build/out/bin", "b")
        try write("src/y.log", "l")
        try write("src/.DS_Store", "finder")
        try write("photo.jpg.atdrive-partial", "half")
        let found = try IgnoredFiles.local(in: folder.path, settings: IgnoreSettings())
        // Outermost only; the sync's own things never.
        #expect(found.map(\.path) == [".env", "build", "src/.DS_Store", "src/y.log", "x.log"])
        #expect(found.map(\.isFolder) == [false, true, false, false, false])
        let withoutGit = try IgnoredFiles.local(in: folder.path, settings: IgnoreSettings(respectGitignore: false))
        #expect(!withoutGit.map(\.path).contains(".env"))
    }

    @Test func findsWhatsIgnoredInTheDrive() async throws {
        try await put("/.atdriveignore", "*.log\nbuild/\n")
        try await put("/docs/.gitignore", "*.tmp\n")
        try await put("/build/out/bin", "b")
        try await put("/docs/run.log", "l")
        try await put("/docs/scratch.tmp", "t")
        try await put("/docs/keep.txt", "k")
        try await put("/notes.txt", "n")
        let tree = try await other.tree()
        func find(_ settings: IgnoreSettings) async throws -> [String] {
            try await IgnoredFiles.inDrive(tree, settings: settings) { node in
                var data = Data()
                try await other.read(node) { data += $0 }
                return String(decoding: data, as: UTF8.self)
            }.map { tree.path(of: $0).description }
        }
        #expect(try await find(IgnoreSettings()) == ["/build", "/docs/run.log", "/docs/scratch.tmp"])
        #expect(try await find(IgnoreSettings(respectGitignore: false)) == ["/build", "/docs/run.log"])
    }

    // MARK: atdrive dev list-ignored / delete-ignored

    @Test func picksOnlyAFolderSyncedWithTheDrive() async throws {
        let elsewhere = try temporaryDirectory().path
        let path = folder.standardizedFileURL.path
        // Not synced yet: refused by name, and not picked otherwise.
        #expect(throws: IgnoredFiles.NotSynced.self) {
            try IgnoredFiles.folder(named: path, installed: nil, standard: path, drive: drive)
        }
        #expect(
            try IgnoredFiles.folder(named: nil, installed: nil, standard: path, drive: drive)
                == .none(installedElsewhere: nil))

        try await open().sync()
        #expect(
            try IgnoredFiles.folder(named: path, installed: elsewhere, standard: elsewhere, drive: drive)
                == .named(path))
        #expect(
            try IgnoredFiles.folder(named: nil, installed: path, standard: elsewhere, drive: drive) == .installed(path))
        #expect(try IgnoredFiles.folder(named: nil, installed: nil, standard: path, drive: drive) == .standard(path))
        // The installed one wins over ~/atdrive, and isn't swapped for it when it's not synced.
        #expect(
            try IgnoredFiles.folder(named: nil, installed: elsewhere, standard: path, drive: drive)
                == .none(installedElsewhere: elsewhere))
        #expect(throws: IgnoredFiles.NotSynced.self) {
            try IgnoredFiles.folder(named: elsewhere, installed: path, standard: path, drive: drive)
        }
    }

    @Test func listsAndDeletesWhatsIgnoredOnBothSides() async throws {
        try write(".atdriveignore", "*.log\nbuild/\n")
        try write("a.txt", "a")
        try write("x.log", "local only")
        try write("build/out/bin", "local build")
        let sync = try open()
        try await sync.sync()
        // In the drive from somewhere that doesn't ignore them.
        try await put("/build/old.bin", "old")
        try await put("/docs/run.log", "log")
        try await put("/docs/keep.txt", "keep")
        try await sync.sync()

        let joined = JoinedDrive(home: drive, access: nil)
        let choice = IgnoredFiles.Folder.standard(folder.path)
        let found = try await IgnoredFiles.find(in: joined, folder: choice, settings: IgnoreSettings())
        #expect(found.local == [.init(path: "build", isFolder: true), .init(path: "x.log", isFolder: false)])
        #expect(found.remote.map { found.tree.path(of: $0).description } == ["/build", "/docs/run.log"])

        let trash = try temporaryDirectory()
        var deletions: [IgnoredFiles.Deletion] = []
        try await IgnoredFiles.delete(
            found, in: joined,
            trash: { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                try FileManager.default.moveItem(atPath: path, toPath: trash.appendingPathComponent(name).path)
            },
            report: { deletions.append($0) })
        #expect(
            deletions == [
                .init(path: "build", isFolder: true, inDrive: false, count: 1),
                .init(path: "x.log", isFolder: false, inDrive: false, count: 1),
                .init(path: "/build", isFolder: true, inDrive: true, count: 2),
                .init(path: "/docs/run.log", isFolder: false, inDrive: true, count: 1),
            ])
        // Here: in this computer's trash, not deleted.
        #expect(try localFiles() == [".atdriveignore", "a.txt", "docs/", "docs/keep.txt"])
        #expect(try String(contentsOf: trash.appendingPathComponent("x.log"), encoding: .utf8) == "local only")
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("build/out/bin").path))
        // In the drive: in its trash.
        #expect(try await driveFiles() == [".atdriveignore", "a.txt", "docs/", "docs/keep.txt"])
        let trashed = try await other.update(nil).trash().map(\.record.name)
        #expect(Set(trashed).isSuperset(of: ["build", "old.bin", "run.log"]))
        // Nothing for the sync to do, and nothing left to find.
        #expect(try await sync.sync().changes == 0)
        #expect(try await IgnoredFiles.find(in: joined, folder: choice, settings: IgnoreSettings()).isEmpty)
    }

    @Test func somethingTheTrashWontTakeIsLeftAndReported() async throws {
        try write(".atdriveignore", "*.log\n")
        try write("a.log", "a")
        try write("b.log", "b")
        try await open().sync()
        let joined = JoinedDrive(home: drive, access: nil)
        let found = try await IgnoredFiles.find(
            in: joined, folder: .standard(folder.path), settings: IgnoreSettings())
        struct Refused: Error, CustomStringConvertible { var description: String { "no room" } }
        var deletions: [IgnoredFiles.Deletion] = []
        try await IgnoredFiles.delete(
            found, in: joined,
            trash: { path in
                if path.hasSuffix("a.log") { throw Refused() }
                try FileManager.default.removeItem(atPath: path)
            },
            report: { deletions.append($0) })
        #expect(deletions.map(\.problem) == ["no room", nil])
        #expect(try localFiles() == [".atdriveignore", "a.log"])
    }
}

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
}

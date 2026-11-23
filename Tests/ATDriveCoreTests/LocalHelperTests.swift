import Foundation
import Testing

@testable import ATDriveCore

/// The unit file `atdrive sync --install` writes, and this computer's trash.
@Suite struct LocalHelperTests {
    @Test func readsBackTheFolderAUnitSyncs() {
        let words = ["/usr/local/bin/atdrive", "sync", "/home/me/My \"Drive\" 100% $HOME \\ here", "--interval", "60"]
        let unit = """
            [Unit]
            Description=ATDrive

            [Service]
            ExecStart=\(words.map { SystemdUnit.quote($0, forCommand: true) }.joined(separator: " "))
            Environment=\(SystemdUnit.quote("A=b", forCommand: false))

            """
        #expect(SystemdUnit.command(in: unit) == words)
        #expect(SystemdUnit.command(in: "[Service]\nRestart=always\n") == nil)
    }

    #if os(Linux)
        @Test func movesThingsToTheTrash() throws {
            let root = try temporaryDirectory()
            let trash = root.appendingPathComponent("Trash").path
            let folder = root.appendingPathComponent("my files")
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("build/out"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("build/out/bin"))
            try Data("one".utf8).write(to: folder.appendingPathComponent("a 100%.log"))

            try SystemTrash.move(folder.appendingPathComponent("build").path, homeTrash: trash)
            try SystemTrash.move(folder.appendingPathComponent("a 100%.log").path, homeTrash: trash)
            // A second one with the same name gets another.
            try Data("two".utf8).write(to: folder.appendingPathComponent("a 100%.log"))
            try SystemTrash.move(folder.appendingPathComponent("a 100%.log").path, homeTrash: trash)

            let files = try FileManager.default.contentsOfDirectory(atPath: "\(trash)/files").sorted()
            #expect(files == ["a 100%.log", "a 100%.log.2", "build"])
            #expect(FileManager.default.fileExists(atPath: "\(trash)/files/build/out/bin"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
            let info = try String(contentsOfFile: "\(trash)/info/a 100%.log.2.trashinfo", encoding: .utf8)
            let original = folder.appendingPathComponent("a 100%.log").standardizedFileURL.path
            #expect(info.hasPrefix("[Trash Info]\nPath=\(SystemTrash.escape(original))\nDeletionDate="))
            #expect(SystemTrash.escape(original).contains("my%20files/a%20100%25.log"))
            #expect(throws: SystemTrash.Failure.self) {
                try SystemTrash.move(folder.appendingPathComponent("gone").path, homeTrash: trash)
            }
        }
    #endif
}

extension FolderSyncTests {
    @Test func knowsWhichFoldersAreSyncedWithTheDrive() async throws {
        #expect(!FolderSync.isSynced(folder.path, with: drive))
        try await open().sync()
        #expect(FolderSync.isSynced(folder.path, with: drive))
        #expect(!FolderSync.isSynced(try temporaryDirectory().path, with: drive))
    }
}

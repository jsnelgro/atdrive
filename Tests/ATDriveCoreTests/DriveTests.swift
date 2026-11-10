import Foundation
import Testing

@testable import ATDriveCore

@Suite struct DriveTests {
    let pds = FakePDS()
    let drive: Drive
    let directory: URL

    init() async throws {
        drive = pds.device()
        _ = try await drive.create()
        directory = try temporaryDirectory()
    }

    func localFile(_ name: String, _ contents: String, modified: Date? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    @Test func aNewDriveIsEmpty() async throws {
        #expect(try await drive.tree().nodes.isEmpty)
        #expect(pds.spaceExists)
    }

    /// Only `create` makes a drive: it has a recovery key to show. A write doesn't.
    @Test func writesDontCreateADrive() async throws {
        let empty = FakePDS()
        let device = empty.device(keyring: Keyring(DriveKey()))
        await #expect(throws: DriveAccessError.noDrive) { try await device.createFolder(named: "x", in: nil) }
        #expect(!empty.spaceExists)
        #expect(try await device.tree().nodes.isEmpty)
    }

    @Test func uploadsInChunksAndDownloadsIdentically() async throws {
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        let file = try localFile("notes.txt", "hello, atproto!", modified: modified)  // 15 bytes

        let node = try await drive.upload(file, as: "notes.txt", in: nil)
        #expect(node.record.chunks?.count == 4)  // 4 + 4 + 4 + 3
        #expect(node.record.size == 15)
        #expect(node.record.sha256 == "2c4e50c0db301eb66910b359774d9c15298d04fb1ebdd79f96214abc4eabd01b")  // sha256sum

        let tree = try await drive.tree()
        let stored = try #require(try tree.locate(DrivePath("/notes.txt")))
        #expect(stored.record == node.record)

        let out = directory.appendingPathComponent("out.txt")
        try await drive.download(stored, to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello, atproto!")
        let restored = try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date
        #expect(restored == modified)
        #expect(try drive.isUnchanged(out, comparedTo: stored))
        #expect(try !drive.isUnchanged(try localFile("other.txt", "hello, atproto?"), comparedTo: stored))
    }

    @Test func explicitModificationTimeWins() async throws {
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        let node = try await drive.upload(try localFile("m.txt", "x"), as: "m.txt", in: nil, modified: date)
        #expect(node.record.modifiedDate == date)
    }

    @Test func emptyFiles() async throws {
        let node = try await drive.upload(try localFile("empty", ""), as: "empty", in: nil)
        #expect(node.record.chunks == [])
        let out = directory.appendingPathComponent("empty-out")
        try await drive.download(node, to: out)
        #expect(try Data(contentsOf: out).isEmpty)
    }

    @Test func replacingKeepsIdentity() async throws {
        let first = try await drive.upload(try localFile("a.txt", "one"), as: "a.txt", in: nil)
        let second = try await drive.upload(
            try localFile("a.txt", "two, longer"), as: "a.txt", in: nil, replacing: first)
        #expect(second.id == first.id)
        #expect(second.record.createdAt == first.record.createdAt)
        // The settings, this device's record and the recovery record; the node, and a version for
        // each write.
        #expect(pds.recordCount == 6)
        #expect(second.record.version != first.record.version)
    }

    @Test func corruptedDownloadIsRejectedAndLeavesNothing() async throws {
        let node = try await drive.upload(try localFile("x.bin", "important"), as: "x.bin", in: nil)
        pds.corruptDownloads = true
        let out = directory.appendingPathComponent("x-out.bin")
        await #expect(throws: ATDriveError.self) { try await drive.download(node, to: out) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["x.bin"])
    }

    @Test func foldersMovesAndDeletes() async throws {
        let docs = try await drive.createFolder(named: "docs", in: nil)
        let archive = try await drive.createFolder(named: "archive", in: docs.id)
        let file = try await drive.upload(try localFile("r.txt", "report"), as: "r.txt", in: nil)
        try await drive.move(file, to: archive.id, as: "report.txt")

        var tree = try await drive.tree()  // 4 records over 2 pages
        #expect(try tree.locate(DrivePath("/docs/archive/report.txt"))?.id == file.id)
        #expect(tree.children(of: nil).map(\.name) == ["docs"])

        try await drive.delete(tree.descendants(of: docs.id) + [docs])
        tree = try await drive.tree()
        #expect(tree.nodes.isEmpty)
    }

    @Test func oddRecordsAreUnreadableNotFatalOrDropped() async throws {
        let keyring = try #require(drive.keyring)
        try pds.insertSealed(
            rkey: "3aaaaaaaaaaa2", ["name": "future", "kind": "symlink", "createdAt": "2026-01-01T00:00:00Z"],
            keyring: keyring)
        try pds.insertSealed(
            rkey: "3aaaaaaaaaaa3", ["name": "ok", "kind": "folder", "createdAt": "2026-01-01T00:00:00Z"],
            keyring: keyring)
        try pds.insertSealed(
            rkey: "3aaaaaaaaaaa4", ["name": "..", "kind": "file", "createdAt": "2026-01-01T00:00:00Z"],
            keyring: keyring)
        // Not sealed at all: from before drives were encrypted, or made up by the PDS.
        pds.insertRawRecord(
            rkey: "3aaaaaaaaaaa5",
            ["$type": Lexicon.node, "name": "plain", "kind": "folder", "createdAt": "2026-01-01T00:00:00Z"])
        // Sealed with a drive key this device doesn't have.
        try pds.insertSealed(
            rkey: "3aaaaaaaaaaa6", ["name": "secret", "kind": "folder", "createdAt": "2026-01-01T00:00:00Z"],
            keyring: Keyring(DriveKey()))
        let tree = try await drive.tree()
        #expect(tree.children(of: nil).map(\.name) == ["ok"])
        #expect(
            tree.unreadable.mapValues(\.reason) == [
                "3aaaaaaaaaaa2": .newerFormat, "3aaaaaaaaaaa4": .invalidName, "3aaaaaaaaaaa5": .newerFormat,
                "3aaaaaaaaaaa6": .missingKey,
            ])
        #expect(tree.unreadable["3aaaaaaaaaaa2"]?.cid == pds.cid(of: "3aaaaaaaaaaa2"))
    }

    @Test func rejectsInvalidNames() async throws {
        await #expect(throws: ATDriveError.invalidName("a/b")) { try await drive.createFolder(named: "a/b", in: nil) }
    }
}

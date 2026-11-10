import Foundation
import Testing

@testable import ATDriveCore

/// What the history commands (`history`, `restore`, `trash`, `purge`, `du`) need from the core
/// beyond `HistoryTests`: finding things by path in the drive or the trash, and what a restore
/// skipped and why.
@Suite struct HistoryLookupTests {
    let pds = FakePDS()
    let clock = TestClock(HistoryTests.start)
    let laptop: Drive
    let phone: Drive
    let directory: URL

    init() async throws {
        let pds = pds
        let clock = clock
        func device(_ name: String, _ clockID: UInt64, keyring: Keyring? = nil) -> Drive {
            pds.device(name, tids: TIDSource(clockID: clockID) { clock.now }, keyring: keyring)
        }
        laptop = device("laptop", 1)
        _ = try await laptop.create()
        phone = device("phone", 2, keyring: laptop.keyring)
        directory = try temporaryDirectory()
    }

    @discardableResult
    func upload(_ contents: String, as name: String, in parent: String? = nil, replacing: Node? = nil)
        async throws -> Node
    {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return try await laptop.upload(url, as: name, in: parent, replacing: replacing)
    }

    func snapshot() async throws -> DriveSnapshot { try await laptop.update(nil) }

    func contents(_ node: Node) async throws -> String {
        var data = Data()
        try await laptop.read(node) { data += $0 }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Finding things by path

    @Test func findsWhatsThereNowOrElseInTheTrash() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let sub = try await laptop.createFolder(named: "sub", in: docs.id)
        let a = try await upload("a", as: "a.txt", in: sub.id)
        let old = try await upload("old", as: "notes.txt")
        clock.advance(60)
        try await laptop.delete([old])
        clock.advance(60)
        let new = try await upload("new", as: "notes.txt")
        clock.advance(60)
        try await laptop.delete([a, sub])

        let snapshot = try await snapshot()
        let now = clock.now
        #expect(try snapshot.find(DrivePath("/"), now: now) == .root)
        #expect(try snapshot.find(DrivePath("/docs"), now: now) == .node(snapshot.tree.nodes[docs.id]!))
        // There now wins over the trash.
        #expect(try snapshot.find(DrivePath("/notes.txt"), now: now).id == new.id)
        #expect(snapshot.trashed(at: DrivePath("/notes.txt"), now: now)?.id == old.id)
        // Deleted: where it was. That includes what was deleted with its folder.
        let item = try #require(snapshot.trashed(at: DrivePath("/docs/sub"), now: now))
        #expect(item.id == sub.id && item.isFolder)
        #expect(try snapshot.find(DrivePath("/docs/sub"), now: now) == .trashed(item))
        #expect(try snapshot.find(DrivePath("/docs/sub/a.txt"), now: now).id == a.id)
        #expect(throws: ATDriveError.notFound("/docs/b.txt")) { try snapshot.find(DrivePath("/docs/b.txt"), now: now) }

        // What restoring or purging the folder takes with it.
        #expect(snapshot.deletedTogether(item, now: now).map(\.id) == [sub.id, a.id])

        // Past the retention period, it's no longer in the trash.
        let later = now + snapshot.retention + 1
        #expect(snapshot.trashed(at: DrivePath("/docs/sub"), now: later) == nil)
        #expect(throws: ATDriveError.notFound("/docs/sub")) { try snapshot.find(DrivePath("/docs/sub"), now: later) }
    }

    @Test func findsWhatWasInAFolderThatsAFileNow() async throws {
        let folder = try await laptop.createFolder(named: "x", in: nil)
        let inside = try await upload("in", as: "in.txt", in: folder.id)
        try await laptop.delete([inside, folder])
        try await upload("now a file", as: "x")
        let snapshot = try await snapshot()
        #expect(try snapshot.find(DrivePath("/x/in.txt"), now: clock.now).id == inside.id)
        #expect(throws: ATDriveError.notAFolder("/x")) { try snapshot.find(DrivePath("/x/other"), now: clock.now) }
    }

    // MARK: Undoing

    /// Undoing a folder's delete brings back what was deleted with it, as the trash does.
    @Test func undoingAFolderDeleteBringsBackItsContents() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let sub = try await laptop.createFolder(named: "sub", in: docs.id)
        let a = try await upload("a", as: "a.txt", in: sub.id)
        let b = try await upload("b", as: "b.txt", in: docs.id)
        clock.advance(60)
        var snapshot = try await snapshot()
        try await laptop.delete(snapshot.tree.descendants(of: docs.id) + [docs])
        snapshot = try await laptop.update(snapshot)

        let result = try await laptop.restorePrevious(docs.id, in: snapshot)
        #expect(Set(result.restored.map(\.id)) == [docs.id, sub.id, a.id, b.id])
        snapshot = try await laptop.update(snapshot)
        #expect(try await contents(try #require(try snapshot.tree.locate(DrivePath("/docs/sub/a.txt")))) == "a")
        #expect(try snapshot.tree.locate(DrivePath("/docs/b.txt"))?.id == b.id)
        #expect(snapshot.trash(now: clock.now).isEmpty)
    }

    // MARK: What a restore skipped

    @Test func aRestoreSaysWhyItSkippedSomething() async throws {
        let old = try await upload("old", as: "a.txt")
        try await laptop.delete([old])
        let seen = try await snapshot()
        _ = try await laptop.restoreFromTrash([old.id], in: seen)
        let second = try await phone.restoreFromTrash([old.id], in: seen)
        #expect(second.skipped == [old.id] && second.reasons == [old.id: .changedElsewhere])

        // Something this version of atdrive can't read is left alone.
        let file = try await upload("one", as: "b.txt")
        let then = clock.now.addingTimeInterval(1)
        clock.advance(60)
        try await upload("two", as: "b.txt", replacing: file)
        pds.insertRawRecord(  // as a newer version of ATDrive might write it
            rkey: file.id,
            ["$type": Lexicon.node, "name": "b.txt", "kind": "package", "createdAt": "2026-11-09T00:00:00Z"])
        let result = try await laptop.restore(file.id, asOf: then, in: try await snapshot())
        #expect(result.restored.isEmpty && result.skipped == [file.id] && result.reasons == [file.id: .unreadable])

        // A file whose contents went with the version that held them.
        let c = try await upload("cee", as: "c.txt")
        clock.advance(60)
        let renamed = try await laptop.move(c, to: nil, as: "c2.txt")  // points at c's first version
        let afterRename = clock.now.addingTimeInterval(1)
        clock.advance(60)
        try await upload("cee 2", as: "c2.txt", replacing: renamed)
        pds.deleteRawRecord(rkey: try #require(c.record.version), collection: Lexicon.version)
        let gone = try await laptop.restore(c.id, asOf: afterRename, in: try await snapshot())
        #expect(gone.restored.isEmpty && gone.reasons == [c.id: .contentsGone])
    }

    // MARK: Space

    @Test func usageSaysWhatHistoryShares() async throws {
        let a = try await upload("aaaabbbb", as: "a.txt")  // chunks: aaaa, bbbb
        try await upload("aaaacccc", as: "a.txt", replacing: a)  // bbbb now only in history
        let usage = try await snapshot().usage()
        #expect(usage.current == 8 && usage.historyOnly == 4)
        #expect(usage.shared == 8 && usage.sharedChunks == 2)  // aaaa and cccc are in versions too
    }
}

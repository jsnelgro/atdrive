import Foundation
import Testing

@testable import ATDriveCore

/// A clock tests move by hand, so history spans days without waiting.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// History (`DriveHistory`, and `Drive`'s settling, restoring, purging and pruning), against an
/// in-memory PDS whose blobs go once nothing references them. Devices share a hand-moved clock.
@Suite struct HistoryTests {
    static let start = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
    static let day: TimeInterval = 24 * 60 * 60

    let pds = FakePDS()
    let clock = TestClock(HistoryTests.start)
    /// Two devices editing the same drive.
    let laptop: Drive
    let phone: Drive
    let directory: URL

    init() throws {
        let transport = pds
        let clock = clock
        func device(_ name: String, _ clockID: UInt64) -> Drive {
            Drive(
                client: XRPCClient(service: URL(string: "https://pds.test")!, transport: transport),
                owner: "did:plc:test", chunkSize: 4, device: name, tids: TIDSource(clockID: clockID) { clock.now },
                createsDrive: true)
        }
        laptop = device("laptop", 1)
        phone = device("phone", 2)
        directory = try temporaryDirectory()
    }

    // MARK: Helpers

    func file(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func upload(
        _ contents: String, as name: String, in parent: String? = nil, replacing: Node? = nil, by drive: Drive? = nil
    )
        async throws -> Node
    {
        try await (drive ?? laptop).upload(try file(contents), as: name, in: parent, replacing: replacing)
    }

    func snapshot(_ drive: Drive? = nil) async throws -> DriveSnapshot { try await (drive ?? laptop).update(nil) }

    func contents(_ node: Node, drive: Drive? = nil) async throws -> String {
        var data = Data()
        try await (drive ?? laptop).read(node) { data += $0 }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a tree holds, by node ID, in a form two trees can be compared in.
    struct Shape: Equatable, CustomStringConvertible {
        var parent: String?
        var name: String
        var folder: Bool
        var sha256: String?
        var size: Int?
        var chunks: [String]?

        var description: String { "\(parent ?? "/")/\(name)\(folder ? "/" : "") \(sha256?.prefix(6) ?? "")" }
    }

    static func shape(_ tree: DriveTree) -> [String: Shape] {
        var shapes: [String: Shape] = [:]
        for node in tree.nodes.values {
            shapes[node.id] = Shape(
                parent: tree.parent(of: node.id), name: node.name, folder: node.isFolder,
                sha256: node.record.sha256, size: node.record.size, chunks: node.record.chunks?.map(\.cid))
        }
        return shapes
    }

    // MARK: Versions

    @Test func everyWriteRecordsAVersion() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let created = try await upload("one", as: "a.txt", in: docs.id)
        clock.advance(60)
        let edited = try await upload("two!", as: "a.txt", in: docs.id, replacing: created, by: phone)
        clock.advance(60)
        let moved = try await laptop.move(edited, to: nil, as: "b.txt")
        clock.advance(60)
        try await laptop.delete([moved])

        let history = try await snapshot().history
        let versions = history.versions(of: created.id)
        #expect(versions.map(\.record.change) == [.created, .edited, .moved, .deleted])
        #expect(versions.map(\.record.device) == ["laptop", "phone", "laptop", "laptop"])
        #expect(versions.map(\.record.prev) == [nil, versions[0].id, versions[1].id, versions[2].id])
        #expect(created.record.version == versions[0].id && moved.record.version == versions[2].id)
        // Each write's time is its version's key.
        #expect(versions[1].date.timeIntervalSince(versions[0].date).rounded() == 60)

        // Contents are held once: the move points at the edit.
        #expect(versions[1].record.chunks?.count == 1)
        #expect(versions[2].record.chunks == nil && versions[2].record.contentsFrom == versions[1].id)
        #expect(history.record(at: versions[2])?.chunks == edited.record.chunks)
        #expect(versions[2].record.name == "b.txt" && versions[2].record.parent == nil)
        #expect(versions[3].record.state == nil)
        #expect(history.versions(of: docs.id).map(\.record.change) == [.created])
    }

    @Test func theSnapshotFollowsHistoryAndSavesIt() async throws {
        let first = try await upload("one", as: "a.txt")
        var followed = try await snapshot()
        try await upload("two", as: "a.txt", replacing: first)
        let folder = try await laptop.createFolder(named: "f", in: nil)
        try await laptop.delete([folder])
        followed = try await laptop.update(followed)
        let listed = try await laptop.listEverything()
        #expect(followed.history.versions == listed.history.versions)
        #expect(followed.history.versions.count == 4)
        #expect(followed.settings == listed.settings && listed.settings?.retentionDays == 30)
        #expect(listed.settings?.driveID?.count == 32)

        let saved = try #require(try followed.saved())
        let loaded = try #require(DriveSnapshot(saved: saved, drive: laptop))
        #expect(loaded.history.versions == followed.history.versions)
        #expect(loaded.settings == followed.settings)
    }

    // MARK: The drive as it was

    /// Random edits, renames, moves, deletes and restores, from two devices, hours apart, with
    /// the tree noted after each: the drive as of each of those times must be exactly that,
    /// contents included, before pruning and (from the start of the retention period) after.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func historyReplaysTheDriveAtAnyTime(seed: UInt64) async throws {
        var random = SplitMix64(seed: seed)
        pds.pageSize = 50
        pds.opsPageSize = 200
        var snapshot = try await snapshot()
        var noted: [(time: Date, shape: [String: Shape])] = []
        var names = 0
        func name() -> String {
            names += 1
            return "n\(names)"
        }

        for step in 0..<70 {
            clock.advance(Double(Int.random(in: 6...18, using: &random)) * 60 * 60)
            let drive = Bool.random(using: &random) ? laptop : phone
            let tree = snapshot.tree
            let nodes = tree.nodes.values.sorted { $0.id < $1.id }
            let files = nodes.filter { !$0.isFolder }
            let folders = nodes.filter(\.isFolder)
            let contents = String(repeating: "x\(step)", count: Int.random(in: 0...4, using: &random))
            switch Int.random(in: 0..<20, using: &random) {
            case 0...3:
                try await upload(contents, as: name(), in: folders.randomElement(using: &random)?.id, by: drive)
            case 4...5:
                try await drive.createFolder(named: name(), in: folders.randomElement(using: &random)?.id)
            case 6...8:
                if let target = files.randomElement(using: &random) {
                    try await upload(contents, as: target.name, in: target.record.parent, replacing: target, by: drive)
                }
            case 9...11:
                if let node = nodes.randomElement(using: &random) {
                    let into = folders.filter { !tree.isInside($0.id, folder: node.id) }.randomElement(using: &random)
                    try await drive.move(node, to: Bool.random(using: &random) ? into?.id : nil, as: name())
                }
            case 12...13:
                if let node = nodes.randomElement(using: &random) {
                    try await drive.delete(node.isFolder ? tree.descendants(of: node.id) + [node] : [node])
                }
            case 14...15:
                if let item = snapshot.trash(now: clock.now).randomElement(using: &random) {
                    try await drive.restoreFromTrash([item.id], in: snapshot)
                }
            case 16...17:
                if let earlier = noted.randomElement(using: &random),
                    let id = earlier.shape.keys.sorted().randomElement(using: &random)
                {
                    try await drive.restore(id, asOf: earlier.time, in: snapshot)
                }
            default:
                if let node = nodes.randomElement(using: &random),
                    snapshot.history.previousVersion(of: node.id, current: tree) != nil
                {
                    try await drive.restorePrevious(node.id, in: snapshot)
                }
            }
            snapshot = try await laptop.update(snapshot)
            noted.append((clock.now.addingTimeInterval(1), Self.shape(snapshot.tree)))
        }
        // It did a bit of everything.
        let changes = snapshot.history.versions.values.map(\.record.change)
        #expect(Set(changes) == [.created, .edited, .moved, .deleted, .restored], "seed \(seed)")
        let busy = noted.filter { $0.shape.count > 2 }.count
        #expect(changes.count > 45 && busy > 40, "seed \(seed): \(changes.count) versions, \(busy) busy")
        #expect(Self.shape(snapshot.tree(at: Self.start)).isEmpty)
        for (index, (time, shape)) in noted.enumerated() {
            #expect(Self.shape(snapshot.tree(at: time)) == shape, "seed \(seed), step \(index)")
        }
        for (time, _) in noted.enumerated().filter({ $0.offset % 7 == 0 }).map(\.element) {
            for node in snapshot.tree(at: time).nodes.values where !node.isFolder {
                _ = try await contents(node)  // every chunk there, and the whole file checks out
            }
        }

        // Prune with the retention period starting part way through.
        let now = Self.start + 45 * Self.day
        let cutoff = now - snapshot.retention
        let pruned = try await laptop.prune(snapshot, now: now)
        #expect(pruned > 0)
        snapshot = try await laptop.update(snapshot)
        let before = try #require(noted.last { $0.time < cutoff })
        #expect(Self.shape(snapshot.tree(at: cutoff)) == before.shape, "seed \(seed): the start of the period")
        for (index, (time, shape)) in noted.enumerated() where time >= cutoff {
            let past = snapshot.tree(at: time)
            #expect(Self.shape(past) == shape, "seed \(seed), step \(index), after pruning")
            if index % 5 == 0 {
                for node in past.nodes.values where !node.isFolder { _ = try await contents(node) }
            }
        }
        // Pruning again finds nothing more.
        #expect(try await laptop.prune(snapshot, now: now) == 0)
    }

    @Test func pathsAreLookedUpAsOfThen() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let file = try await upload("draft", as: "a.txt", in: docs.id)
        let then = clock.now.addingTimeInterval(1)
        clock.advance(3600)
        let archive = try await laptop.createFolder(named: "archive", in: nil)
        let moved = try await laptop.move(file, to: archive.id, as: "final.txt")
        try await upload("final", as: "final.txt", in: archive.id, replacing: moved)

        let snapshot = try await snapshot()
        let past = snapshot.tree(at: then)
        let found = try #require(try past.locate(DrivePath("/docs/a.txt")))
        #expect(found.id == file.id)
        #expect(try await contents(found) == "draft")
        #expect(try past.find(DrivePath("/archive")) == .missing)
        #expect(try await contents(try #require(try snapshot.tree.locate(DrivePath("/archive/final.txt")))) == "final")
        #expect(snapshot.history.node(file.id, at: then, current: snapshot.tree)?.name == "a.txt")
    }

    // MARK: Races

    /// Two devices with stale snapshots edit the same file: the second node write wins, but
    /// both versions survive, and settling (by both devices, even at once) makes exactly one
    /// conflicted copy of the other.
    @Test func editsRacingMakeOneConflictedCopy() async throws {
        let original = try await upload("v1", as: "notes.txt")
        clock.advance(60)
        try await upload("laptop's edit", as: "notes.txt", replacing: original, by: laptop)
        let lost = try await snapshot().tree.nodes[original.id]!.record.version!
        try await upload("phone's edit", as: "notes.txt", replacing: original, by: phone)  // stale

        let seenByLaptop = try await snapshot(laptop)
        let seenByPhone = try await snapshot(phone)
        let versions = seenByLaptop.history.versions(of: original.id)
        #expect(versions.count == 3)
        #expect(versions[1].record.prev == versions[0].id && versions[2].record.prev == versions[0].id)
        #expect(seenByLaptop.entries(.node(original.id)).filter(\.lost).map(\.id) == [lost])

        let settled = try await laptop.settleRaces(in: seenByLaptop, now: clock.now)
        #expect(settled.map(\.outcome) == [.conflictedCopy])
        #expect(settled.first?.written.id == lost)  // the copy's ID is the lost version's
        #expect(try await phone.settleRaces(in: seenByPhone, now: clock.now).isEmpty)  // at the same time

        let after = try await snapshot()
        #expect(after.tree.nodes.count == 2)
        #expect(try await contents(after.tree.nodes[original.id]!) == "phone's edit")
        let copy = try #require(after.tree.nodes[lost])
        #expect(copy.name.hasPrefix("notes (conflicted copy "))
        #expect(try await contents(copy) == "laptop's edit")
        // Settled once and for all, even after the file changes again.
        try await upload("v3", as: "notes.txt", replacing: after.tree.nodes[original.id]!)
        #expect(try await laptop.settleRaces(in: try await snapshot(), now: clock.now).isEmpty)
        // And if the copy is deleted, it stays deleted.
        try await laptop.delete([copy])
        #expect(try await phone.settleRaces(in: try await snapshot(phone), now: clock.now).isEmpty)
        #expect(try await snapshot().tree.nodes[lost] == nil)
    }

    @Test func anEditDeletedOverIsRestored() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let original = try await upload("v1", as: "a.txt", in: docs.id)
        try await upload("edited", as: "a.txt", in: docs.id, replacing: original, by: laptop)
        try await phone.delete([original, docs])  // stale: it didn't see the edit

        let seen = try await snapshot()
        #expect(seen.tree.nodes.isEmpty)
        let settled = try await laptop.settleRaces(in: seen, now: clock.now)
        #expect(settled.map(\.outcome) == [.restore])
        #expect(try await phone.settleRaces(in: try await snapshot(phone), now: clock.now).isEmpty)
        #expect(try await laptop.settleRaces(in: seen, now: clock.now).count <= 1)  // stale: nothing doubled

        let after = try await snapshot()
        let restored = try #require(try after.tree.locate(DrivePath("/docs/a.txt")))
        #expect(restored.id == original.id && after.tree.nodes[docs.id] != nil)  // its folder came back too
        #expect(try await contents(restored) == "edited")
        #expect(after.tree.nodes.count == 2)
        #expect(after.history.versions(of: original.id).last?.record.change == .restored)

        // Deleted again on purpose: it stays deleted.
        try await laptop.delete([restored])
        #expect(try await laptop.settleRaces(in: try await snapshot(), now: clock.now).isEmpty)
    }

    @Test func aMoveAndAnEditRacingKeepBoth() async throws {
        let folder = try await laptop.createFolder(named: "folder", in: nil)
        let original = try await upload("v1", as: "a.txt")
        try await upload("edited", as: "a.txt", replacing: original, by: phone)
        try await laptop.move(original, to: folder.id, as: "a.txt")  // stale: writes v1's contents back

        let settled = try await laptop.settleRaces(in: try await snapshot(), now: clock.now)
        #expect(settled.map(\.outcome) == [.contents])
        let after = try await snapshot()
        let node = try #require(try after.tree.locate(DrivePath("/folder/a.txt")))
        #expect(try await contents(node) == "edited")
        #expect(after.tree.nodes.count == 2)
        #expect(try await phone.settleRaces(in: try await snapshot(phone), now: clock.now).isEmpty)
    }

    @Test func aLostMoveOrDeleteIsDroppedButKept() async throws {
        let folder = try await laptop.createFolder(named: "folder", in: nil)
        let a = try await upload("a", as: "a.txt")
        let b = try await upload("b", as: "b.txt")
        try await laptop.move(a, to: folder.id, as: "a.txt")
        try await upload("a, edited", as: "a.txt", replacing: a, by: phone)  // stale: moves it back
        try await laptop.delete([b])
        try await upload("b, edited", as: "b.txt", replacing: b, by: phone)  // an edit outlives a delete

        let snapshot = try await snapshot()
        #expect(try await laptop.settleRaces(in: snapshot, now: clock.now).isEmpty)
        #expect(try await contents(try #require(try snapshot.tree.locate(DrivePath("/a.txt")))) == "a, edited")
        #expect(try await contents(try #require(try snapshot.tree.locate(DrivePath("/b.txt")))) == "b, edited")
        // Both lost changes are still in history.
        let lost = snapshot.entries(.drive).filter(\.lost)
        #expect(Set(lost.map(\.change)) == [.moved, .deleted])
        #expect(lost.first { $0.change == .moved }?.path == DrivePath("/folder/a.txt"))
    }

    @Test func racesOlderThanTheRetentionPeriodAreLeftAlone() async throws {
        let original = try await upload("v1", as: "a.txt")
        try await upload("one", as: "a.txt", replacing: original, by: laptop)
        try await upload("two", as: "a.txt", replacing: original, by: phone)
        let snapshot = try await snapshot()
        #expect(try await laptop.settleRaces(in: snapshot, now: clock.now + 31 * Self.day).isEmpty)
    }

    // MARK: The trash

    @Test func restoringFromTheTrashBringsBackTheFoldersAboveIt() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let sub = try await laptop.createFolder(named: "sub", in: docs.id)
        let a = try await upload("a", as: "a.txt", in: sub.id)
        let b = try await upload("b", as: "b.txt", in: docs.id)
        let gone = try await upload("gone", as: "gone.txt", in: docs.id)
        clock.advance(3600)
        try await laptop.delete([gone])  // earlier, on its own
        clock.advance(3600)
        var snapshot = try await snapshot()
        try await laptop.delete(snapshot.tree.descendants(of: docs.id) + [docs])

        snapshot = try await laptop.update(snapshot)
        let trash = snapshot.trash(now: clock.now)
        #expect(Set(trash.map(\.id)) == [docs.id, sub.id, a.id, b.id, gone.id])
        #expect(Set(trash.filter { !$0.deletedWithFolder }.map(\.id)) == [docs.id, gone.id])
        #expect(trash.first { $0.id == a.id }?.path == DrivePath("/docs/sub/a.txt"))

        // One file: the folders above it come back, nothing else.
        var result = try await laptop.restoreFromTrash([a.id], in: snapshot)
        #expect(result.restored.map(\.id) == [docs.id, sub.id, a.id])
        snapshot = try await laptop.update(snapshot)
        #expect(try await contents(try #require(try snapshot.tree.locate(DrivePath("/docs/sub/a.txt")))) == "a")
        #expect(snapshot.tree.nodes.count == 3)
        #expect(Set(snapshot.trash(now: clock.now).map(\.id)) == [b.id, gone.id])
        #expect(snapshot.history.versions(of: a.id).last?.record.change == .restored)

        // Already back: not in the trash.
        await #expect(throws: ATDriveError.notFound(a.id)) { try await laptop.restoreFromTrash([a.id], in: snapshot) }

        // A folder comes back with what was deleted with it, but not what was deleted before.
        clock.advance(3600)
        try await laptop.delete([
            snapshot.tree.nodes[a.id]!, snapshot.tree.nodes[sub.id]!, snapshot.tree.nodes[docs.id]!,
        ])
        snapshot = try await laptop.update(snapshot)
        result = try await laptop.restoreFromTrash([docs.id], in: snapshot)
        snapshot = try await laptop.update(snapshot)
        #expect(Set(result.restored.map(\.id)) == [docs.id, sub.id, a.id])
        #expect(snapshot.tree.nodes[b.id] == nil)  // deleted with docs the first time, not this time
        #expect(snapshot.trash(now: clock.now).map(\.id).sorted() == [b.id, gone.id].sorted())
    }

    @Test func aRestoredNameThatsTakenGetsAConflictedCopyName() async throws {
        let old = try await upload("old", as: "a.txt")
        try await laptop.delete([old])
        let new = try await upload("new", as: "a.txt")
        let result = try await laptop.restoreFromTrash([old.id], in: try await snapshot())
        let restored = try #require(result.restored.first)
        #expect(restored.id == old.id && restored.name.hasPrefix("a (conflicted copy "))
        let tree = try await snapshot().tree
        #expect(try tree.locate(DrivePath("/a.txt"))?.id == new.id)
    }

    @Test func twoDevicesRestoringAtOnceRestoreOnce() async throws {
        let old = try await upload("old", as: "a.txt")
        try await laptop.delete([old])
        let seen = try await snapshot()
        let first = try await laptop.restoreFromTrash([old.id], in: seen)
        let second = try await phone.restoreFromTrash([old.id], in: seen)
        #expect(first.restored.map(\.id) == [old.id])
        #expect(second.restored.isEmpty && second.skipped == [old.id])
        #expect(try await snapshot().history.versions(of: old.id).filter { $0.record.change == .restored }.count == 1)
    }

    // MARK: Restoring to a time

    @Test func restoringAFolderToATime() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let a = try await upload("a1", as: "a.txt", in: docs.id)
        let b = try await upload("b1", as: "b.txt", in: docs.id)
        let c = try await upload("c1", as: "c.txt", in: docs.id)
        let then = clock.now.addingTimeInterval(1)
        clock.advance(3600)
        let elsewhere = try await laptop.createFolder(named: "elsewhere", in: nil)
        try await upload("a2", as: "a.txt", in: docs.id, replacing: a)
        try await laptop.move(b, to: elsewhere.id, as: "b, moved.txt")
        try await laptop.delete([c])
        try await laptop.move(docs, to: docs.record.parent, as: "documents")
        let added = try await upload("new", as: "new.txt", in: docs.id)

        let result = try await laptop.restore(docs.id, asOf: then, in: try await snapshot())
        #expect(result.skipped.isEmpty)
        let snapshot = try await snapshot()
        let tree = snapshot.tree
        #expect(try await contents(try #require(try tree.locate(DrivePath("/docs/a.txt")))) == "a1")
        #expect(try tree.locate(DrivePath("/docs/b.txt"))?.id == b.id)  // moved back
        #expect(try await contents(try #require(try tree.locate(DrivePath("/docs/c.txt")))) == "c1")  // undeleted
        #expect(try tree.locate(DrivePath("/docs/new.txt"))?.id == added.id)  // added since: stays
        #expect(tree.children(of: elsewhere.id).isEmpty)

        // It's history too, so it can be undone.
        #expect(snapshot.history.versions(of: a.id).last?.record.change == .restored)
        try await laptop.restorePrevious(a.id, in: snapshot)
        #expect(try await contents(try await self.snapshot().tree.nodes[a.id]!) == "a2")
    }

    @Test func undoingTheLatestChange() async throws {
        let a = try await upload("one", as: "a.txt")
        let edited = try await upload("two", as: "a.txt", replacing: a)
        try await laptop.move(edited, to: nil, as: "b.txt")
        var snapshot = try await snapshot()
        try await laptop.restorePrevious(a.id, in: snapshot)  // the rename
        snapshot = try await laptop.update(snapshot)
        #expect(try snapshot.tree.locate(DrivePath("/a.txt"))?.id == a.id)
        try await laptop.restorePrevious(a.id, in: snapshot)  // the undo itself
        snapshot = try await laptop.update(snapshot)
        #expect(try snapshot.tree.locate(DrivePath("/b.txt"))?.id == a.id)

        try await laptop.delete([snapshot.tree.nodes[a.id]!])
        snapshot = try await laptop.update(snapshot)
        try await laptop.restorePrevious(a.id, in: snapshot)  // the delete
        snapshot = try await laptop.update(snapshot)
        #expect(try await contents(try #require(try snapshot.tree.locate(DrivePath("/b.txt")))) == "two")
    }

    // MARK: History listings

    @Test func historyListsChangesWithTheirPathsAtTheTime() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let other = try await laptop.createFolder(named: "other", in: nil)
        let a = try await upload("1", as: "a.txt", in: docs.id)
        clock.advance(60)
        try await upload("2", as: "a.txt", in: docs.id, replacing: a, by: phone)
        clock.advance(60)
        let moved = try await laptop.move(try await snapshot().tree.nodes[a.id]!, to: other.id, as: "a.txt")
        clock.advance(60)
        try await laptop.delete([moved])
        try await upload("x", as: "x.txt", in: other.id)

        let snapshot = try await snapshot()
        let ofFile = snapshot.entries(.node(a.id))
        #expect(ofFile.map(\.change) == [.deleted, .moved, .edited, .created])
        #expect(
            ofFile.map(\.path) == ["/other/a.txt", "/other/a.txt", "/docs/a.txt", "/docs/a.txt"].map(DrivePath.init))
        #expect(ofFile.map(\.device) == ["laptop", "laptop", "phone", "laptop"])
        #expect(ofFile.allSatisfy { !$0.lost })
        #expect(ofFile.map(\.date) == ofFile.map(\.date).sorted(by: >))

        // A folder: itself, and what was in it at the time.
        #expect(snapshot.entries(.folder(docs.id)).map(\.change) == [.edited, .created, .created])
        #expect(snapshot.entries(.folder(other.id)).map(\.name) == ["x.txt", "a.txt", "a.txt", "other"])
        #expect(snapshot.entries(.drive).count == 7)
    }

    // MARK: Space

    @Test func usageCountsEachChunkOnce() async throws {
        let a = try await upload("aaaabbbb", as: "a.txt")  // chunks: aaaa, bbbb
        try await upload("aaaabbbb", as: "copy.txt")  // the same chunks
        try await upload("aaaacccc", as: "a.txt", replacing: a)  // bbbb now only in history
        let usage = try await snapshot().usage()
        #expect(usage.current == 12 && usage.currentChunks == 3)  // aaaa, bbbb (the copy), cccc
        #expect(usage.historyOnly == 0)
        let gone = try await snapshot().tree.locate(DrivePath("/copy.txt"))!
        try await laptop.delete([gone])
        let after = try await snapshot().usage()
        #expect(after.current == 8 && after.historyOnly == 4 && after.total == 12)
    }

    // MARK: Purging

    @Test func purgingDeletesEveryVersionAndItsChunks() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let a = try await upload("secret", as: "a.txt", in: docs.id)
        try await upload("secret 2", as: "a.txt", in: docs.id, replacing: a)
        let keep = try await upload("keep", as: "keep.txt")
        let chunks = try await snapshot().history.versions(of: a.id).flatMap { $0.record.chunks ?? [] }.map(\.cid)

        let deleted = try await laptop.purge([docs.id], in: try await snapshot())
        #expect(deleted == 5)  // two nodes, three versions
        let snapshot = try await snapshot()
        #expect(snapshot.tree.nodes.keys.sorted() == [keep.id])
        #expect(snapshot.history.versions(of: a.id).isEmpty && snapshot.history.versions(of: docs.id).isEmpty)
        #expect(snapshot.trash(now: clock.now).isEmpty)
        #expect(!chunks.contains(where: pds.hasBlob))

        // From the trash too, with what was deleted with it.
        let folder = try await laptop.createFolder(named: "f", in: nil)
        try await upload("in", as: "in.txt", in: folder.id)
        try await laptop.delete(try await self.snapshot().tree.descendants(of: folder.id) + [folder])
        #expect(try await laptop.emptyTrash(in: try await self.snapshot()) == 4)
        let after = try await self.snapshot()
        #expect(after.trash(now: clock.now).isEmpty && after.history.versions.count == 1)  // keep.txt's
        await #expect(throws: ATDriveError.notFound(folder.id)) {
            try await laptop.purge([folder.id], in: after)
        }
    }

    // MARK: Pruning

    @Test func pruningKeepsWhatTheStartOfThePeriodNeeds() async throws {
        let a = try await upload("AAAA", as: "a.txt")  // day 0
        clock.advance(Self.day)
        let edited = try await upload("BBBB", as: "a.txt", replacing: a)  // day 1
        clock.advance(9 * Self.day)
        try await laptop.move(edited, to: nil, as: "renamed.txt")  // day 10: points at day 1's chunks
        let doomed = try await upload("doomed", as: "doomed.txt")
        clock.advance(Self.day)
        try await laptop.delete([doomed])  // day 11, before the period
        let trashed = try await upload("trashed", as: "trashed.txt")
        clock.advance(19 * Self.day)
        try await laptop.delete([try await snapshot().tree.nodes[trashed.id]!])  // day 30, in the period
        let firstChunks = a.record.chunks!.map(\.cid)

        let now = Self.start + 45 * Self.day  // the period starts on day 15
        var snapshot = try await snapshot()
        let before = Set(snapshot.history.versions.keys)
        let pruned = try await laptop.prune(snapshot, now: now)
        snapshot = try await laptop.update(snapshot)
        let after = Set(snapshot.history.versions.keys)
        #expect(pruned == before.count - after.count)

        let ofA = snapshot.history.versions(of: a.id)
        #expect(ofA.map(\.record.change) == [.edited, .moved])  // the rename, and what it takes contents from
        #expect(snapshot.history.versions(of: doomed.id).isEmpty)  // deleted before the period: all gone
        #expect(snapshot.history.versions(of: trashed.id).count == 2)  // in the trash: kept
        #expect(!firstChunks.contains(where: pds.hasBlob))  // day 0's contents went with its version
        let atStart = snapshot.tree(at: now - snapshot.retention)
        #expect(try await contents(try #require(atStart.nodes[a.id])) == "BBBB")
        #expect(try await contents(try #require(atStart.nodes[trashed.id])) == "trashed")

        // Restoring from the trash still works, from what was kept.
        try await laptop.restoreFromTrash([trashed.id], in: snapshot)
        #expect(try await contents(try await self.snapshot().tree.nodes[trashed.id]!) == "trashed")
    }

    @Test func devicesPruningAtOnceSkipWhatTheOtherDeleted() async throws {
        let a = try await upload("1", as: "a.txt")
        var node = a
        for index in 2...6 {
            clock.advance(Self.day)
            node = try await upload("\(index)", as: "a.txt", replacing: node)
        }
        let now = clock.now + 33 * Self.day
        let seen = try await snapshot()
        let first = try await laptop.prune(seen, now: now)
        #expect(first == 5)  // all but the latest
        // The other device works from the same, now stale, snapshot: every version it wants
        // to delete is already gone, so it skips them all without failing.
        #expect(try await phone.prune(seen, now: now) == 0)
        #expect(try await snapshot().history.versions(of: a.id).count == 1)
    }

    // MARK: Blobs

    @Test func historyKeepsOldChunksAlive() async throws {
        pds.blobGrace = 2
        let a = try await upload("old!", as: "a.txt")
        let then = clock.now.addingTimeInterval(1)
        clock.advance(60)
        try await upload("new!", as: "a.txt", replacing: a)
        for index in 0..<5 { try await laptop.createFolder(named: "f\(index)", in: nil) }  // past the grace
        let old = a.record.chunks!.map(\.cid)
        #expect(old.allSatisfy(pds.hasBlob))  // the first version still references them
        let past = try await snapshot().tree(at: then)
        #expect(try await contents(past.nodes[a.id]!) == "old!")

        // A blob nothing ever referenced goes after the grace period; one still in use doesn't.
        let stray = try await laptop.client.uploadBlob(Data("stray".utf8), mimeType: "application/octet-stream")
        for index in 0..<3 { try await laptop.createFolder(named: "g\(index)", in: nil) }
        #expect(!pds.hasBlob(stray.cid))
        #expect(old.allSatisfy(pds.hasBlob))
    }

    // MARK: Deleting folders

    @Test func aFolderDeleteIsBatchedAndRecordsEveryItem() async throws {
        let top = try await laptop.createFolder(named: "top", in: nil)
        var snapshot = try await snapshot()
        let inside = (0..<249).map { index in
            laptop.change(
                .create, node: TID.next(), record: NodeRecord(name: "f\(index)", parent: top.id, kind: .folder),
                .created, prev: nil)
        }
        _ = try await laptop.commit(inside)
        snapshot = try await laptop.update(snapshot)
        #expect(snapshot.tree.nodes.count == 250)

        // One of them goes elsewhere first: it's skipped, not an error.
        try await phone.delete([snapshot.tree.nodes[inside[7].node]!])
        clock.advance(60)
        let calls = pds.calls.count
        try await laptop.delete(snapshot.tree.descendants(of: top.id) + [top])
        let writes = pds.calls[calls...].filter { $0 == "com.atproto.space.applyWrites" }.count
        // 100 + 100 + 50 items; then the batch that raced, one at a time.
        #expect(writes == 3 + 100 || writes == 3 + 50)

        snapshot = try await laptop.update(snapshot)
        #expect(snapshot.tree.nodes.isEmpty)
        let trash = snapshot.trash(now: clock.now)
        #expect(trash.count == 250)
        #expect(trash.filter { !$0.deletedWithFolder }.map(\.id).sorted() == [top.id, inside[7].node].sorted())
        let result = try await laptop.restoreFromTrash([top.id], in: snapshot)
        #expect(result.restored.count == 249)
    }

    // MARK: Drive identity

    @Test func creatingADriveWritesItsSettingsOnce() async throws {
        let first = try await laptop.create()
        let second = try await phone.create()
        #expect(first == second && first.driveID != nil)
        #expect(try await laptop.settings() == first)
    }

    @Test func aWriteCreatesAMissingDriveOnlyWhenAllowed() async throws {
        let careful = laptop.with(createsDrive: false)
        await #expect(throws: XRPCError.self) { try await careful.createFolder(named: "x", in: nil) }
        #expect(!pds.spaceExists)
        try await laptop.createFolder(named: "x", in: nil)
        #expect(pds.spaceExists)
        #expect(try await laptop.settings()?.driveID != nil)
    }

    // MARK: Small parts

    @Test func tidsSayWhen() {
        let date = Date(timeIntervalSince1970: 1_767_225_600.123456)
        let source = TIDSource(clockID: 5) { date }
        let first = source.next()
        let second = source.next()
        #expect(first < second && TID.isValid(first))
        #expect(abs(TID.date(first)!.timeIntervalSince(date)) < 0.000_01)
        #expect(TID.lowest(at: date) <= first && first <= TID.highest(at: date))
        #expect(TID.highest(at: date.addingTimeInterval(-0.001)) < first)
        #expect(TID.date("not a tid") == nil)
    }

    @Test func lostChangeRules() {
        #expect(ConflictRules.lostChange(base: .some("a"), lost: nil, current: .some("b")) == .dropped)  // a delete
        #expect(ConflictRules.lostChange(base: .some("a"), lost: .some("a"), current: .some("b")) == .dropped)  // a move
        #expect(ConflictRules.lostChange(base: .some("a"), lost: .some("b"), current: nil) == .restore)
        #expect(ConflictRules.lostChange(base: .some("a"), lost: .some("b"), current: .some("a")) == .contents)
        #expect(ConflictRules.lostChange(base: .some("a"), lost: .some("b"), current: .some("b")) == .dropped)
        #expect(ConflictRules.lostChange(base: .some("a"), lost: .some("b"), current: .some("c")) == .conflictedCopy)
        // Folders have no contents: only a delete over them brings one back.
        #expect(ConflictRules.lostChange(base: nil, lost: .some(nil), current: .some(nil)) == .dropped)
        #expect(ConflictRules.lostChange(base: nil, lost: .some(nil), current: nil) == .restore)
    }
}

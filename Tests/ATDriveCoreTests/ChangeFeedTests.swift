import Foundation
import Testing

@testable import ATDriveCore

/// The change feed (`listRepoOps`), and keeping a `DriveSnapshot` current with it.
@Suite struct ChangeFeedTests {
    let pds = FakePDS()
    let drive: Drive

    init() {
        drive = pds.device()
    }

    /// Writes a node record directly (sealed, no blobs), as any device would.
    @discardableResult
    func put(_ id: String, _ name: String, in parent: String? = nil, folder: Bool = false, sha: String = "x")
        async throws -> String
    {
        let record = NodeRecord(
            name: name, parent: parent, kind: folder ? .folder : .file, size: folder ? nil : 1,
            sha256: folder ? nil : sha, chunks: folder ? nil : [])
        if !pds.spaceExists { _ = try await drive.create() }
        return try await drive.client.putSpaceRecord(
            space: drive.space, repo: drive.owner, collection: Lexicon.node, rkey: id,
            record: try drive.stored(record, id: id))
    }

    func listings(since index: Int) -> Int {
        pds.calls[index...].filter { $0 == "com.atproto.space.listRecords" }.count
    }

    /// Whole-drive listings (however many pages each), by the commit each starts from.
    func fullListings(since index: Int) -> Int {
        pds.calls[index...].filter { $0 == "com.atproto.space.getLatestCommit" }.count
    }

    /// The snapshot saved and loaded again, as after a restart.
    func reloaded(_ snapshot: DriveSnapshot) throws -> DriveSnapshot {
        let saved = try #require(try snapshot.saved())
        return try #require(DriveSnapshot(saved: saved, drive: drive))
    }

    /// The commit the drive is at now.
    func latestCommit() async throws -> RepoCommit {
        try #require(try await drive.client.latestSpaceCommit(space: drive.space, repo: drive.owner))
    }

    /// The snapshot matches what a fresh full listing says, in every respect sync relies on.
    func expectSame(
        _ snapshot: DriveSnapshot, _ fresh: DriveSnapshot, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.revision == fresh.revision, sourceLocation: sourceLocation)
        #expect(snapshot.repo.records == fresh.repo.records, sourceLocation: sourceLocation)
        // Kept current op by op, the hash is still the one over the records.
        #expect(snapshot.repo.hash == RepoState(records: snapshot.repo.records).hash, sourceLocation: sourceLocation)
        #expect(snapshot.tree.nodes == fresh.tree.nodes, sourceLocation: sourceLocation)
        #expect(snapshot.tree.unreadable == fresh.tree.unreadable, sourceLocation: sourceLocation)
        #expect(snapshot.history.versions == fresh.history.versions, sourceLocation: sourceLocation)
        #expect(snapshot.history.unreadable == fresh.history.unreadable, sourceLocation: sourceLocation)
        #expect(snapshot.settings == fresh.settings, sourceLocation: sourceLocation)
        for node in fresh.history.nodeIDs {
            #expect(
                snapshot.history.versions(of: node) == fresh.history.versions(of: node), sourceLocation: sourceLocation)
        }
        for id in fresh.tree.nodes.keys {
            #expect(snapshot.tree.parent(of: id) == fresh.tree.parent(of: id), sourceLocation: sourceLocation)
            #expect(
                snapshot.tree.unreadableContainer(of: id) == fresh.tree.unreadableContainer(of: id),
                sourceLocation: sourceLocation)
        }
    }

    // MARK: The feed

    @Test func opsComeInOrderWithTheirValuesAndTheCommitAtTheEnd() async throws {
        try await put("3aaaaaaaaaaa2", "a.txt")
        let start = try #require(pds.revision)
        try await put("3aaaaaaaaaaa3", "b.txt")
        try await put("3aaaaaaaaaaa2", "a, renamed.txt")
        pds.insertRawRecord(rkey: "self", collection: "me.jsnelgro.atdrive.settings", ["retentionDays": 30])
        let changes = try await drive.changes(since: start)

        #expect(changes.ops.map(\.rkey) == ["3aaaaaaaaaaa3", "3aaaaaaaaaaa2", "self"])
        #expect(changes.ops.map(\.collection) == [Lexicon.node, Lexicon.node, "me.jsnelgro.atdrive.settings"])
        #expect(changes.ops[0].prev == nil)  // a create
        #expect(changes.ops[1].prev != nil && changes.ops[1].prev != changes.ops[1].cid)
        #expect(changes.ops[2].value == .object(["retentionDays": .integer(30)]))
        let op = changes.ops[1]
        guard case .readable(let renamed) = drive.readNode(id: op.rkey, cid: op.cid!, value: op.value) else {
            Issue.record("unreadable")
            return
        }
        #expect(renamed.name == "a, renamed.txt")
        #expect(changes.revision == pds.revision)
        #expect(changes.commit?.data == pds.currentCommitData)  // `$bytes`, unpadded
    }

    @Test func pagesAreFollowedToTheHead() async throws {
        pds.opsPageSize = 3
        try await put("3aaaaaaaaaaa2", "first")
        let start = try #require(pds.revision)
        for index in 0..<10 { try await put("3aaaaaaaaab\(index)a", "file \(index)") }

        var calls = pds.calls.count
        var changes = try await drive.changes(since: start)
        #expect(changes.ops.count == 10)
        #expect(changes.ops.map(\.value).allSatisfy { $0 != nil })
        #expect(pds.calls[calls...].filter { $0 == "com.atproto.space.listRepoOps" }.count == 4)  // 3+3+3+1

        // A last page that's exactly full has no commit: one more (empty) page brings it.
        try await put("3aaaaaaaaac2", "eleventh")
        try await put("3aaaaaaaaac3", "twelfth")
        calls = pds.calls.count
        changes = try await drive.changes(since: start)
        #expect(changes.ops.count == 12)
        #expect(changes.revision == pds.revision)
        #expect(pds.calls[calls...].filter { $0 == "com.atproto.space.listRepoOps" }.count == 5)
    }

    @Test func replacedVersionsComeWithoutValues() async throws {
        try await put("3aaaaaaaaaaa2", "keep")
        let start = try #require(pds.revision)
        try await put("3aaaaaaaaaaa3", "v1")
        try await put("3aaaaaaaaaaa3", "v2")
        try await put("3aaaaaaaaaaa3", "v3")
        try await put("3aaaaaaaaaaa4", "doomed")
        pds.deleteRawRecord(rkey: "3aaaaaaaaaaa4")

        var snapshot = try await drive.update(nil)
        let changes = try await drive.changes(since: start)
        #expect(changes.ops.map { $0.value != nil } == [false, false, true, false, false])
        #expect(changes.ops.last?.cid == nil)  // the delete

        // Following the feed from `start` ends where a listing does.
        try await put("3aaaaaaaaaaa3", "v4")
        try await put("3aaaaaaaaaaa3", "v5")
        let calls = pds.calls.count
        snapshot = try await drive.update(snapshot)
        #expect(listings(since: calls) == 0)
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa3"]?.name == "v5")
        expectSame(snapshot, try await drive.listEverything())
    }

    @Test func aCurrentVersionWithoutItsValueIsAGap() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        var snapshot = try await drive.update(nil)
        let held = try #require(snapshot.repo.cid(Lexicon.node, "3aaaaaaaaaaa2"))
        let changes = DriveChanges(
            ops: [
                RepoOp(rev: "3zzzzzzzzzzz2", collection: Lexicon.node, rkey: "3aaaaaaaaaaa2", cid: "new", prev: held)
            ],
            commit: RepoCommit(rev: "3zzzzzzzzzzz2", data: Data(count: 32)))
        #expect(throws: ChangeFeedGap.self) {
            try snapshot.apply(changes, strict: true, reading: drive)
        }
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa2"]?.name == "a")  // unchanged
    }

    // MARK: Gaps

    @Test func aCompactedFeedThatDoesntConnectMeansAFullListing() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        var snapshot = try await drive.update(nil)
        try await put("3aaaaaaaaaaa2", "a, edited")
        let compacted = try #require(pds.revision)
        try await put("3aaaaaaaaaaa2", "a, edited again")
        pds.compactOps(through: compacted)  // the feed now starts at an op whose prev we never saw

        let calls = pds.calls.count
        snapshot = try await drive.update(snapshot)
        #expect(listings(since: calls) > 0)
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa2"]?.name == "a, edited again")
        expectSame(snapshot, try await drive.listEverything())
    }

    @Test func aRevisionThatMovedWithoutOpsMeansAFullListing() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        var snapshot = try await drive.update(nil)
        pds.clearRecords()
        let calls = pds.calls.count
        snapshot = try await drive.update(snapshot)
        #expect(listings(since: calls) > 0)
        #expect(snapshot.tree.nodes.isEmpty)
        #expect(snapshot.revision == pds.revision)
    }

    @Test func theCheckCatchesAWriteCompactionHid() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        let start = Date()
        var snapshot = try await drive.update(nil, now: start)
        try await put("3aaaaaaaaaaa3", "missed")
        pds.insertRawRecord(rkey: "self", collection: "me.jsnelgro.atdrive.settings", ["retentionDays": 30])
        let compacted = try #require(pds.revision)
        try await put("3aaaaaaaaaaa2", "a, edited")
        pds.compactOps(through: compacted)

        // Nothing in the feed shows the missed writes (the edit's `prev` is the CID we hold), but
        // the records don't match the commit, so the drive is listed straight away.
        let calls = pds.calls.count
        snapshot = try await drive.update(snapshot, now: start + 60)
        #expect(fullListings(since: calls) == 1)
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa3"]?.name == "missed")
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa2"]?.name == "a, edited")
        #expect(snapshot.repo.cid("me.jsnelgro.atdrive.settings", "self") != nil)
        #expect(snapshot.verified)
    }

    @Test func aSavedSnapshotThatVerifiesIsntListedAgain() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        let snapshot = try await drive.update(nil)
        let saved = try #require(try snapshot.saved())
        try await put("3aaaaaaaaaaa3", "b")  // while it wasn't running
        let loaded = try #require(DriveSnapshot(saved: saved, drive: drive))
        expectSame(loaded, snapshot)
        #expect(!loaded.listedThisRun && loaded.verified && !loaded.needsFullListing())

        let calls = pds.calls.count
        let updated = try await drive.update(loaded)
        #expect(Array(pds.calls[calls...]) == ["com.atproto.space.listRepoOps"])
        #expect(updated.verified && updated.tree.nodes["3aaaaaaaaaaa3"]?.name == "b")
        expectSame(updated, try await drive.listEverything())

        #expect(DriveSnapshot(saved: Data("{}".utf8), drive: drive) == nil)
    }

    @Test func aSavedSnapshotThatDoesntVerifyIsListedAgain() async throws {
        // Saved unverified (its listing didn't match): listed again on start.
        pds.lyingCommits = .max
        try await put("3aaaaaaaaaaa2", "a")
        let unverified = try await drive.update(nil)
        var loaded = try reloaded(unverified)
        #expect(!loaded.verified && loaded.needsFullListing())
        var calls = pds.calls.count
        _ = try await drive.update(loaded)
        #expect(fullListings(since: calls) == 1)

        // Saved verified, but a write the feed no longer shows came in while it wasn't running.
        pds.lyingCommits = 0
        let verified = try await drive.update(nil)
        try await put("3aaaaaaaaaaa3", "missed")
        let compacted = try #require(pds.revision)
        try await put("3aaaaaaaaaaa2", "a, edited")
        pds.compactOps(through: compacted)
        loaded = try reloaded(verified)
        calls = pds.calls.count
        let updated = try await drive.update(loaded)
        #expect(fullListings(since: calls) == 1)
        #expect(updated.verified && updated.tree.nodes["3aaaaaaaaaaa3"]?.name == "missed")
    }

    @Test func theHashStateIsSavedWithTheSnapshot() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        pds.insertRawRecord(rkey: "self", collection: "me.jsnelgro.atdrive.settings", ["retentionDays": 30])
        let snapshot = try await drive.update(nil)
        let saved = try #require(try snapshot.saved())
        let loaded = try #require(DriveSnapshot(saved: saved, drive: drive))
        #expect(loaded.repo == snapshot.repo)  // the records, the commit and the hash
        #expect(!loaded.repo.hash.setHash.isEmpty)

        // A save without the state, or with a broken one, gets it from the records.
        var json = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect((json["setHash"] as? String).flatMap { Data(base64Encoded: $0) } == snapshot.repo.hash.setHash.state)
        for broken in [nil, Data(count: 7).base64EncodedString()] {
            json["setHash"] = broken
            let recomputed = try #require(
                DriveSnapshot(saved: try JSONSerialization.data(withJSONObject: json), drive: drive))
            #expect(recomputed.repo == snapshot.repo)
            #expect(recomputed.verified)
        }
    }

    // MARK: The exact check

    @Test func theCheckPassesAfterAListingAndAfterOps() async throws {
        try await put("3aaaaaaaaaaa2", "folder", folder: true)
        try await put("3aaaaaaaaaaa3", "a.txt", in: "3aaaaaaaaaaa2")
        pds.insertRawRecord(
            rkey: "3aaaaaaaaaaa4", ["$type": Lexicon.node, "name": "x", "kind": "package", "createdAt": "2026"])
        pds.insertRawRecord(rkey: "self", collection: "me.jsnelgro.atdrive.settings", ["retentionDays": 30])
        var snapshot = try await drive.update(nil)
        let listed = try await latestCommit()
        #expect(snapshot.repo.check(listed))
        #expect(snapshot.verified && snapshot.mismatch == nil)

        try await put("3aaaaaaaaaaa3", "a, edited.txt", in: "3aaaaaaaaaaa2")
        pds.deleteRawRecord(rkey: "3aaaaaaaaaaa4")
        pds.insertRawRecord(rkey: "self", collection: "me.jsnelgro.atdrive.settings", ["retentionDays": 7])
        pds.insertRawRecord(rkey: "3aaaaaaaaaaa5", collection: "me.jsnelgro.atdrive.version", ["n": 1])
        let calls = pds.calls.count
        snapshot = try await drive.update(snapshot)
        #expect(listings(since: calls) == 0)
        let latest = try await latestCommit()
        #expect(snapshot.repo.check(latest) && snapshot.verified)
        #expect(!snapshot.repo.check(listed))

        // Every record counts, in every collection: leave one out, or hold an old CID, and the
        // check fails.
        for (collection, rkey) in [(Lexicon.node, "3aaaaaaaaaaa3"), ("me.jsnelgro.atdrive.version", "3aaaaaaaaaaa5")] {
            var missing = snapshot.repo
            missing.set(collection, rkey, cid: nil)
            #expect(!missing.check(latest))
            var old = snapshot.repo
            old.set(collection, rkey, cid: "bafyreiold")
            #expect(!old.check(latest))
        }
    }

    @Test func aMismatchMeansAFullListing() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        var snapshot = try await drive.update(nil)
        try await put("3aaaaaaaaaaa2", "a, edited")
        pds.lyingCommits = 1  // the feed connects, but the commit at its end doesn't match
        let calls = pds.calls.count
        snapshot = try await drive.update(snapshot)
        #expect(fullListings(since: calls) == 1)
        #expect(snapshot.verified && snapshot.mismatch == nil)
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa2"]?.name == "a, edited")
    }

    @Test func aListingThatNeverMatchesIsntRepeated() async throws {
        pds.lyingCommits = .max  // as a server that hashes differently
        try await put("3aaaaaaaaaaa2", "a")
        var calls = pds.calls.count
        var snapshot = try await drive.update(nil)
        #expect(fullListings(since: calls) == 1)
        #expect(!snapshot.verified && snapshot.mismatch != nil)
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa2"]?.name == "a")

        // A verified snapshot whose check fails is listed once, not again and again.
        pds.lyingCommits = 0
        snapshot = try await drive.update(nil)
        #expect(snapshot.verified)
        pds.lyingCommits = .max
        try await put("3aaaaaaaaaaa3", "b")
        calls = pds.calls.count
        snapshot = try await drive.update(snapshot)
        #expect(fullListings(since: calls) == 1)
        #expect(!snapshot.verified && snapshot.mismatch != nil)
        #expect(snapshot.tree.nodes["3aaaaaaaaaaa3"]?.name == "b")
    }

    @Test func theFallbackRunsOnlyWhileTheCheckFails() async throws {
        pds.lyingCommits = .max
        try await put("3aaaaaaaaaaa2", "a")
        let start = Date()
        var snapshot = try await drive.update(nil, now: start)
        #expect(!snapshot.verified)

        // Unverified, it follows the feed without listing every time...
        try await put("3aaaaaaaaaaa3", "b")
        var calls = pds.calls.count
        snapshot = try await drive.update(snapshot, now: start + 60)
        #expect(fullListings(since: calls) == 0)
        #expect(!snapshot.verified && snapshot.tree.nodes["3aaaaaaaaaaa3"]?.name == "b")
        // ...and lists the whole drive every hour.
        let hour = DriveSnapshot.fullListingInterval
        calls = pds.calls.count
        snapshot = try await drive.update(snapshot, now: start + hour)
        #expect(fullListings(since: calls) == 1)

        // Once a check passes, the hourly listing stops.
        pds.lyingCommits = 0
        calls = pds.calls.count
        snapshot = try await drive.update(snapshot, now: start + hour + 60)
        #expect(fullListings(since: calls) == 0)
        #expect(snapshot.verified && snapshot.mismatch == nil)
        #expect(!snapshot.needsFullListing(at: start + 100 * hour))
        calls = pds.calls.count
        snapshot = try await drive.update(snapshot, now: start + 3 * hour)
        #expect(Array(pds.calls[calls...]) == ["com.atproto.space.listRepoOps"])
    }

    @Test func anIdleUpdateIsOneRequest() async throws {
        try await put("3aaaaaaaaaaa2", "a")
        let snapshot = try await drive.update(nil)
        let calls = pds.calls.count
        let same = try await drive.update(snapshot)
        #expect(Array(pds.calls[calls...]) == ["com.atproto.space.listRepoOps"])
        expectSame(same, snapshot)
    }

    @Test func aDriveThatsGoneHasNoRevision() async throws {
        #expect(try await drive.update(nil).revision == nil)  // never written
        try await put("3aaaaaaaaaaa2", "a")
        let snapshot = try await drive.update(nil)
        #expect(snapshot.revision != nil)
        pds.wipe()
        let gone = try await drive.update(snapshot)
        #expect(gone.revision == nil && gone.tree.nodes.isEmpty)
    }

    // MARK: Unreadable records

    @Test func unreadableRecordsAreKeptNotDropped() async throws {
        try await put("3aaaaaaaaaaa2", "folder", folder: true)
        var snapshot = try await drive.update(nil)
        pds.insertRawRecord(
            rkey: "3aaaaaaaaaaa3", ["$type": Lexicon.node, "name": "x", "kind": "package", "createdAt": "2026"])
        try await put("3aaaaaaaaaaa4", "inside.txt", in: "3aaaaaaaaaaa3")
        snapshot = try await drive.update(snapshot)

        let unreadable = try #require(snapshot.tree.unreadable["3aaaaaaaaaaa3"])
        #expect(unreadable.reason == .newerFormat)
        #expect(unreadable.cid == pds.cid(of: "3aaaaaaaaaaa3"))
        // What's inside it stays inside it, out of sight.
        #expect(snapshot.tree.unreadableContainer(of: "3aaaaaaaaaaa4") == "3aaaaaaaaaaa3")
        #expect(snapshot.tree.children(of: nil).map(\.name) == ["folder"])
        expectSame(snapshot, try await drive.listEverything())
    }

    // MARK: Applying ops = listing

    /// Random writes from several "devices" (puts, moves into folders, cycles, deletes, batches,
    /// unreadable records, other collections), with the snapshot brought up to date at random
    /// points: it must always equal a fresh listing, without listing anything itself.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func applyingChangesMatchesAFreshListing(seed: UInt64) async throws {
        var random = SplitMix64(seed: seed)
        pds.pageSize = 7
        pds.opsPageSize = 5
        let ids = (0..<24).map { "3aaaaaaaaa\(String(format: "%02d", $0))a" }
        try await put(ids[0], "root folder", folder: true)
        var snapshot = try await drive.update(nil)

        for _ in 0..<30 {
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                let id = ids.randomElement(using: &random)!
                let parent = Bool.random(using: &random) ? nil : ids.randomElement(using: &random)
                switch Int.random(in: 0..<10, using: &random) {
                case 0...3:
                    try await put(
                        id, "n\(Int.random(in: 0..<5, using: &random))", in: parent,
                        folder: Bool.random(using: &random), sha: "\(Int.random(in: 0..<3, using: &random))")
                case 4, 5:
                    if pds.cid(of: id) != nil { pds.deleteRawRecord(rkey: id) }
                case 6:
                    // Several deletes in one commit.
                    let tree = try await drive.tree()
                    let doomed = Array(tree.nodes.values.prefix(Int.random(in: 1...3, using: &random)))
                    if !doomed.isEmpty { try await drive.delete(doomed) }
                case 7:
                    pds.insertRawRecord(
                        rkey: id, ["$type": Lexicon.node, "name": "z", "kind": "package", "createdAt": "2026"])
                case 8:
                    // A version, readable or not, of one of a few nodes.
                    let node = ids[Int.random(in: 0..<3, using: &random)]
                    pds.insertRawRecord(
                        rkey: id, collection: Lexicon.version,
                        Bool.random(using: &random)
                            ? [
                                "node": node, "change": "deleted",
                                "device": "d\(Int.random(in: 0..<9, using: &random))",
                            ]
                            : ["node": node, "n": Int.random(in: 0..<100, using: &random)])
                default:
                    if pds.cid(of: id, collection: "me.jsnelgro.atdrive.version") != nil {
                        pds.deleteRawRecord(rkey: id, collection: "me.jsnelgro.atdrive.version")
                    }
                }
            }
            guard Bool.random(using: &random) else { continue }
            let calls = pds.calls.count
            snapshot = try await drive.update(snapshot)
            #expect(listings(since: calls) == 0, "seed \(seed): followed the feed")
            #expect(snapshot.verified, "seed \(seed): checked against the commit")
            expectSame(snapshot, try await drive.listEverything())
        }
        snapshot = try await drive.update(snapshot)
        expectSame(snapshot, try await drive.listEverything())
    }
}

/// A small seedable generator, so random tests repeat exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

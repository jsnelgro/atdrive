import Foundation
import Testing

@testable import ATDriveCore

/// Moving file contents: chunks cut where the contents say, sent only when the drive doesn't
/// have them, fetched only when the local copy doesn't, a few at a time. Requests are counted
/// by the in-memory PDS.
@Suite struct TransferTests {
    let pds = FakePDS()
    let laptop: Drive
    let recoveryKey: RecoveryKey
    let directory: URL

    /// Chunks of about 4 KiB, so a file of a few hundred KiB has dozens.
    static let small = TransferOptions(chunking: .init(minSize: 1 << 10, averageSize: 4 << 10, maxSize: 16 << 10))

    init() async throws {
        laptop = pds.device("laptop", transfers: Self.small)
        recoveryKey = try await laptop.create()
        directory = try temporaryDirectory()
    }

    /// Another device with the drive's keys.
    func device(_ name: String, _ transfers: TransferOptions = small, clock: TestClock? = nil) -> Drive {
        let tids = clock.map { clock in TIDSource(clockID: 2) { clock.now } } ?? .system
        return pds.device(name, transfers: transfers, tids: tids, keyring: laptop.keyring)
    }

    /// Bytes that look random, the same for the same seed (splitmix64).
    static func noise(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                state &+= 0x9E37_79B9_7F4A_7C15
                var word = state
                word = (word ^ (word >> 30)) &* 0xBF58_476D_1CE4_E5B9
                word = (word ^ (word >> 27)) &* 0x94D0_49BB_1331_11EB
                word ^= word >> 31
                let take = min(8, count - offset)
                withUnsafeBytes(of: &word) { word in
                    bytes.baseAddress!.advanced(by: offset).copyMemory(from: word.baseAddress!, byteCount: take)
                }
                offset += take
            }
        }
        return data
    }

    func file(_ data: Data, _ name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func contents(_ node: Node, drive: Drive? = nil) async throws -> Data {
        var data = Data()
        try await (drive ?? laptop).read(node) { data += $0 }
        return data
    }

    /// The chunks the drive has, as `drive` lists it.
    func known(_ drive: Drive? = nil) async throws -> Set<String> {
        try await (drive ?? laptop).update(nil).chunkCIDs
    }

    /// The CIDs of `after`'s chunks that `before` doesn't have.
    static func new(_ after: Node, since before: Node) -> Set<String> {
        Set((after.record.chunks ?? []).map(\.cid)).subtracting((before.record.chunks ?? []).map(\.cid))
    }

    /// Whether progress only went forward, from 0 to `total`.
    static func isMonotonic(_ progress: [Int], to total: Int) -> Bool {
        progress == progress.sorted() && progress.last == total
    }

    // MARK: Uploading only what changed

    @Test func anInsertNearTheStartUploadsAChunkOrTwo() async throws {
        let drive = device("standard chunks", .standard)
        let original = Self.noise(20 << 20, seed: 1)
        let first = try await drive.upload(try file(original), as: "big.bin", in: nil)
        #expect((first.record.chunks?.count ?? 0) >= 10)  // about 1 MiB each
        var edited = original
        edited.insert(contentsOf: Data("an insert near the start".utf8), at: 5000)
        pds.resetCounts()
        let second = try await drive.upload(
            try file(edited), as: "big.bin", in: nil, replacing: first, known: try await known(drive))
        #expect(pds.uploads == Self.new(second, since: first).count)
        #expect((1...3).contains(pds.uploads))
        #expect(try await contents(second, drive: drive) == edited)
    }

    @Test func appendingUploadsOnlyTheTail() async throws {
        let original = Self.noise(1 << 20, seed: 2)
        let first = try await laptop.upload(try file(original), as: "log.bin", in: nil)
        let before = try #require(first.record.chunks)
        let appended = original + Self.noise(20_000, seed: 3)
        pds.resetCounts()
        let second = try await laptop.upload(
            try file(appended), as: "log.bin", in: nil, replacing: first, known: try await known())
        let after = try #require(second.record.chunks)
        // Every chunk but the old last one is still there, in place; what follows is new.
        #expect(Array(after.prefix(before.count - 1)) == Array(before.dropLast()))
        #expect(pds.uploads == after.count - (before.count - 1))
        #expect(try await contents(second) == appended)
    }

    @Test func copyingAFileUploadsNothing() async throws {
        let data = Self.noise(300_000, seed: 4)
        let original = try await laptop.upload(try file(data), as: "a.bin", in: nil)
        pds.resetCounts()
        let copy = try await laptop.upload(try file(data), as: "copy.bin", in: nil, known: try await known())
        #expect(pds.uploads == 0)
        #expect(copy.record.chunks == original.record.chunks)
        #expect(try await contents(copy) == data)

        // Chunks only history has count too: here, both deleted (so in the trash).
        try await laptop.delete([original, copy])
        pds.resetCounts()
        let again = try await laptop.upload(try file(data), as: "again.bin", in: nil, known: try await known())
        #expect(pds.uploads == 0)
        #expect(try await contents(again) == data)
    }

    /// Keys rotate when a device is removed. Chunks are cut and named with the first key, so
    /// the same contents come out as the same chunks, which the drive already has.
    @Test func chunksStayTheSameAfterKeysRotate() async throws {
        let data = Self.noise(200_000, seed: 5)
        let before = try await laptop.upload(try file(data), as: "a.bin", in: nil)
        let phone = pds.device("phone", transfers: Self.small)
        try await phone.unlock(recoveryKey: recoveryKey)
        #expect(try await laptop.remove(try #require(phone.identity?.id), recoveryKey: recoveryKey))
        let keyring = try #require(laptop.keyring)
        #expect(keyring.keys.count == 2)

        pds.resetCounts()
        let after = try await laptop.upload(try file(data), as: "again.bin", in: nil, known: try await known())
        #expect(pds.uploads == 0)
        #expect(after.record.chunks == before.record.chunks)  // the same boundaries, IDs and blobs
        let sealed = try #require(pds.rawRecord(rkey: after.id)?["sealed"] as? [String: Any])
        #expect(sealed["keyID"] as? String == keyring.current.id.rawValue)  // the record, though, is new
    }

    /// Another device purges the only file that had some chunks, after this upload decided to
    /// reuse them and before its record is written: the PDS refuses the record, so the chunks go
    /// up after all.
    @Test func aChunkDeletedBeforeTheWriteIsUploadedAgain() async throws {
        let data = Self.noise(100_000, seed: 6)
        let original = try await laptop.upload(try file(data), as: "a.bin", in: nil)
        let version = try #require(original.record.version)
        let known = try await known()
        let purged = Locked(false)
        pds.onRequest = { [weak pds] method in
            guard method == "com.atproto.space.applyWrites" else { return }
            let first = purged.update { done in
                defer { done = true }
                return !done
            }
            guard first else { return }
            pds?.deleteRawRecord(rkey: original.id)
            pds?.deleteRawRecord(rkey: version, collection: Lexicon.version)
        }
        let chunks = Set(try #require(original.record.chunks).map(\.cid))
        let progress = Locked<[Int]>([])
        pds.resetCounts()
        let copy = try await laptop.upload(try file(data), as: "copy.bin", in: nil, known: known) { done, _ in
            progress.update { $0.append(done) }
        }
        pds.onRequest = nil
        #expect(pds.uploads == chunks.count)  // none the first time, then the ones it had reused
        #expect(pds.count("com.atproto.space.applyWrites") == 2)
        #expect(chunks.allSatisfy(pds.hasBlob))
        #expect(copy.record.chunks == original.record.chunks)
        #expect(try await contents(copy) == data)
        #expect(Self.isMonotonic(progress.value, to: data.count))
    }

    // MARK: Downloading only what's missing

    @Test func aDownloadFetchesOnlyWhatTheLocalCopyLacks() async throws {
        let phone = device("phone")
        let data = Self.noise(400_000, seed: 7)
        let first = try await laptop.upload(try file(data), as: "doc.bin", in: nil)
        let local = directory.appendingPathComponent("local copy")
        try await phone.download(first, to: local)

        var edited = data
        edited.replaceSubrange(200_000..<200_010, with: Data("ten bytes!".utf8))
        let second = try await laptop.upload(
            try file(edited), as: "doc.bin", in: nil, replacing: first, known: try await known())
        pds.resetCounts()
        let progress = Locked<[Int]>([])
        try await phone.download(second, to: local, previous: local) { done, _ in progress.update { $0.append(done) } }
        #expect(try Data(contentsOf: local) == edited)
        #expect(pds.downloads == Self.new(second, since: first).count)
        #expect((1...3).contains(pds.downloads))
        #expect(Self.isMonotonic(progress.value, to: edited.count))

        // A local copy that's something else entirely saves nothing, and does no harm.
        pds.resetCounts()
        let other = try file(Self.noise(400_000, seed: 8))
        try await phone.download(second, to: directory.appendingPathComponent("fresh"), previous: other)
        #expect(pds.downloads == second.record.chunks?.count)
        #expect(try Data(contentsOf: directory.appendingPathComponent("fresh")) == edited)
        #expect(try Data(contentsOf: other) == Self.noise(400_000, seed: 8))
    }

    @Test func aLocalCopyThatChangedIsReadAgainNotTrusted() async throws {
        let data = Self.noise(100_000, seed: 9)
        let node = try await laptop.upload(try file(data), as: "a.bin", in: nil)
        let chunks = try #require(node.record.chunks)
        let local = try file(data)
        let key = try #require(laptop.keyring?.keys.first)
        let found = await LocalChunks(of: local, wanted: Set(chunks.map(\.id)), key: key, chunking: Self.small.chunking)
        let cut = try #require(found)
        #expect(cut.count == Set(chunks.map(\.id)).count)
        #expect(try cut.read(chunks[0].id).map(key.chunkID(for:)) == chunks[0].id)
        // Overwritten in place after it was cut: its chunks are no longer where they were.
        let handle = try FileHandle(forWritingTo: local)
        try handle.write(contentsOf: Self.noise(100_000, seed: 10))
        try handle.close()
        #expect(try cut.read(chunks[1].id) == nil)
    }

    // MARK: A few at a time

    @Test func parallelTransfersGiveTheSameBytes() async throws {
        pds.latency = .milliseconds(2)
        let data = Self.noise(250_000, seed: 11)
        var oneAtATime = Self.small
        oneAtATime.parallel = 1
        let one = device("one at a time", oneAtATime)
        let four = device("four at a time")

        pds.resetCounts()
        let a = try await one.upload(try file(data), as: "a.bin", in: nil)
        #expect(pds.mostAtOnce == 1)
        pds.resetCounts()
        let progress = Locked<[Int]>([])
        let b = try await four.upload(try file(data), as: "b.bin", in: nil) { done, _ in
            progress.update { $0.append(done) }
        }
        #expect((2...4).contains(pds.mostAtOnce))
        #expect(pds.uploads == Set(a.record.chunks!.map(\.cid)).count)  // all again: nothing said they're known
        #expect(b.record.chunks == a.record.chunks && b.record.sha256 == a.record.sha256)
        #expect(Self.isMonotonic(progress.value, to: data.count) && progress.value.first == 0)

        pds.resetCounts()
        progress.update { $0 = [] }
        let parallel = directory.appendingPathComponent("parallel")
        try await four.download(b, to: parallel) { done, _ in progress.update { $0.append(done) } }
        #expect((2...4).contains(pds.mostAtOnce))
        #expect(Self.isMonotonic(progress.value, to: data.count))
        let sequential = directory.appendingPathComponent("sequential")
        try await one.download(a, to: sequential)
        #expect(try Data(contentsOf: parallel) == data && Data(contentsOf: sequential) == data)
    }

    @Test func anInterruptedUploadLeavesTheOldVersion() async throws {
        let old = Self.noise(100_000, seed: 12)
        let first = try await laptop.upload(try file(old), as: "a.bin", in: nil)
        let before = try await laptop.update(nil)
        let records = pds.recordCount
        let newer = try file(Self.noise(100_000, seed: 13))

        // Cut off after a few chunks.
        pds.failingAfter["com.atproto.repo.uploadBlob"] = 3
        await #expect(throws: XRPCError.self) {
            try await laptop.upload(newer, as: "a.bin", in: nil, replacing: first)
        }
        pds.failingAfter = [:]
        // Cut off when writing the record.
        pds.failing["com.atproto.space.applyWrites"] = 1
        await #expect(throws: XRPCError.self) {
            try await laptop.upload(newer, as: "a.bin", in: nil, replacing: first)
        }

        let after = try await laptop.update(before)
        #expect(pds.recordCount == records)  // no node, version or chunks record half-written
        #expect(after.tree.nodes[first.id] == first)
        #expect(after.history.versions.keys.sorted() == before.history.versions.keys.sorted())
        #expect(try await contents(try #require(after.tree.nodes[first.id])) == old)
    }

    // MARK: Long chunk lists

    /// Two 8-byte chunks to a record, so 100 bytes take seven `chunks` records.
    static let tiny = TransferOptions(
        chunking: .init(minSize: 8, averageSize: 8, maxSize: 8), chunkListLimit: 600)
    static let hundredBytes = Data((0..<100).map { UInt8($0) })

    func continuationKeys(of version: String?, _ count: Int) -> [String] {
        (1...count).map { Lexicon.continuationKey(of: version ?? "?", $0) }.sorted()
    }

    @Test func aLongChunkListContinuesInChunksRecords() async throws {
        let drive = device("tiny records", Self.tiny)
        let phone = device("phone")  // reads whatever the writer chose
        let before = try await phone.update(nil)
        let node = try await drive.upload(try file(Self.hundredBytes), as: "long.bin", in: nil)
        let version = try #require(node.record.version)
        #expect(node.record.chunks?.count == 13 && node.record.continuations == 7)
        // Neither the node nor its version holds the chunks: the version's chunks records do.
        #expect(pds.rawRecord(rkey: node.id)?["chunks"] == nil)
        #expect(pds.rawRecord(rkey: version, collection: Lexicon.version)?["chunks"] == nil)
        #expect(pds.keys(in: Lexicon.chunks) == continuationKeys(of: version, 7))
        let first = try #require(
            pds.rawRecord(rkey: Lexicon.continuationKey(of: version, 1), collection: Lexicon.chunks))
        #expect(Set(first.keys) == ["$type", "chunks", "sealed"] && (first["chunks"] as? [Any])?.count == 2)

        // Read back: listing the nodes, listing everything, the change feed, a saved snapshot.
        #expect(try await phone.tree().nodes[node.id]?.record == node.record)
        let listed = try await phone.update(nil)
        #expect(listed.tree.nodes[node.id]?.record == node.record)
        #expect(listed.history.version(version)?.record.chunks == node.record.chunks)
        let followed = try await phone.update(before)
        #expect(followed.tree.nodes[node.id]?.record == node.record)
        #expect(followed.history.version(version)?.record.chunks == node.record.chunks)
        let saved = try #require(try listed.saved())
        #expect(DriveSnapshot(saved: saved, drive: phone)?.tree.nodes[node.id]?.record == node.record)
        #expect(try await contents(node, drive: phone) == Self.hundredBytes)

        // A rename points at the same records, and writes none.
        let renamed = try await drive.move(node, to: nil, as: "renamed.bin")
        #expect(pds.keys(in: Lexicon.chunks) == continuationKeys(of: version, 7))
        let after = try await phone.update(followed)
        #expect(after.tree.nodes[node.id]?.record == renamed.record)
        #expect(try await contents(try #require(after.tree.nodes[node.id]), drive: phone) == Self.hundredBytes)
    }

    @Test func anOldVersionInChunksRecordsReadsBack() async throws {
        let clock = TestClock(HistoryTests.start)
        let drive = device("tiny records", Self.tiny, clock: clock)
        let first = try await drive.upload(try file(Self.hundredBytes), as: "a.bin", in: nil)
        let then = clock.now.addingTimeInterval(1)
        clock.advance(60)
        let newer = Data((100..<200).map { UInt8($0) })
        try await drive.upload(try file(newer), as: "a.bin", in: nil, replacing: first)
        var snapshot = try await drive.update(nil)
        let past = try #require(snapshot.tree(at: then).nodes[first.id])
        #expect(past.record.chunks == first.record.chunks)
        #expect(try await contents(past, drive: drive) == Self.hundredBytes)

        // Undoing the edit points the file at the first version's records: none are written.
        let records = pds.keys(in: Lexicon.chunks)
        clock.advance(60)
        try await drive.restorePrevious(first.id, in: snapshot)
        #expect(pds.keys(in: Lexicon.chunks) == records)
        snapshot = try await drive.update(snapshot)
        let restored = try #require(snapshot.tree.nodes[first.id])
        #expect(restored.record.contentsFrom == first.record.version && restored.record.continuations == 7)
        #expect(try await contents(restored, drive: drive) == Self.hundredBytes)
    }

    @Test func chunksRecordsGoWithTheirVersionAndKeepItsChunksTillThen() async throws {
        let clock = TestClock(HistoryTests.start)
        let drive = device("tiny records", Self.tiny, clock: clock)
        let first = try await drive.upload(try file(Self.hundredBytes), as: "a.bin", in: nil)  // day 0
        clock.advance(HistoryTests.day)
        let newer = Data((100..<200).map { UInt8($0) })
        let second = try await drive.upload(try file(newer), as: "a.bin", in: nil, replacing: first)  // day 1
        let oldChunks = try #require(first.record.chunks).map(\.cid)
        let newChunks = try #require(second.record.chunks).map(\.cid)
        #expect(Set(oldChunks).isDisjoint(with: newChunks))
        // Only the first version's chunks records reference its chunks now, and that keeps them.
        for index in 0..<12 { try await drive.createFolder(named: "f\(index)", in: nil) }  // past the blob grace
        #expect(oldChunks.allSatisfy(pds.hasBlob))

        // Pruning past the retention deletes the first version, its records, and so its chunks.
        let pruned = try await drive.prune(try await drive.update(nil), now: HistoryTests.start + 45 * HistoryTests.day)
        #expect(pruned == 1)
        #expect(pds.keys(in: Lexicon.chunks) == continuationKeys(of: second.record.version, 7))
        #expect(!oldChunks.contains(where: pds.hasBlob) && newChunks.allSatisfy(pds.hasBlob))
        let current = try #require(try await drive.tree().nodes[first.id])
        #expect(try await contents(current, drive: drive) == newer)

        // Purging deletes the rest.
        try await drive.purge([first.id], in: try await drive.update(nil))
        #expect(pds.keys(in: Lexicon.chunks).isEmpty)
        #expect(!newChunks.contains(where: pds.hasBlob))
    }

    /// Records too big for one transaction together: the chunks records go first, then the
    /// node and version. Cut off in between, what's left is records nothing names, which
    /// pruning deletes once they're older than the retention.
    @Test func chunksRecordsTooBigForOneTransactionGoFirst() async throws {
        let clock = TestClock(HistoryTests.start)
        var options = Self.tiny
        options.transactionLimit = 2_500
        let drive = device("tiny transactions", options, clock: clock)
        pds.requestLimit = options.transactionLimit + 500

        pds.failingAfter["com.atproto.space.applyWrites"] = 2
        await #expect(throws: XRPCError.self) {
            try await drive.upload(try file(Self.hundredBytes), as: "a.bin", in: nil)
        }
        pds.failingAfter = [:]
        let orphans = pds.keys(in: Lexicon.chunks)
        #expect(!orphans.isEmpty && orphans.count < 7)
        var snapshot = try await drive.update(nil)
        #expect(snapshot.tree.nodes.isEmpty && snapshot.history.versions.isEmpty)
        #expect(try await drive.prune(snapshot, now: clock.now.addingTimeInterval(60)) == 0)
        #expect(pds.keys(in: Lexicon.chunks) == orphans)  // maybe still being written

        pds.resetCounts()
        let node = try await drive.upload(try file(Self.hundredBytes), as: "a.bin", in: nil)
        #expect(pds.count("com.atproto.space.applyWrites") > 1)
        #expect(pds.biggestTransaction <= options.transactionLimit + 500)
        #expect(try await contents(node, drive: drive) == Self.hundredBytes)

        snapshot = try await drive.update(snapshot)
        #expect(try await drive.prune(snapshot, now: clock.now + 45 * HistoryTests.day) == 0)  // no versions
        #expect(pds.keys(in: Lexicon.chunks) == continuationKeys(of: node.record.version, 7))
        #expect(
            try await contents(try #require(try await drive.tree().nodes[node.id]), drive: drive) == Self.hundredBytes)
    }

    // MARK: The synced folder

    @Test func syncFetchesOnlyWhatChangedAndUploadsNothingForACopy() async throws {
        let here = device("here")
        let folder = directory.appendingPathComponent("synced")
        let sync = try FolderSync(folder: folder, drive: here, settle: 0)
        let data = Self.noise(300_000, seed: 14)
        try data.write(to: folder.appendingPathComponent("a.bin"))
        try await sync.sync()

        // A copy made here: there's nothing to upload.
        try data.write(to: folder.appendingPathComponent("copy of a.bin"))
        pds.resetCounts()
        try await sync.sync()
        #expect(pds.uploads == 0)
        let tree = try await laptop.tree()
        #expect(try tree.locate(DrivePath("/copy of a.bin"))?.record.sha256 == Drive.sha256(of: try file(data)))

        // Edited elsewhere: only the chunks that changed come down.
        let node = try #require(try tree.locate(DrivePath("/a.bin")))
        var edited = data
        edited.replaceSubrange(150_000..<150_004, with: Data("edit".utf8))
        let second = try await laptop.upload(
            try file(edited), as: "a.bin", in: nil, replacing: node, known: tree.chunkCIDs)
        pds.resetCounts()
        try await sync.sync()
        #expect(pds.downloads == Self.new(second, since: node).count)
        #expect((1...3).contains(pds.downloads))
        #expect(try Data(contentsOf: folder.appendingPathComponent("a.bin")) == edited)
    }

    // MARK: Speed

    /// Times a 100 MB upload and download against the in-memory PDS, with the standard chunks.
    /// It only prints the numbers: run it with `swift test -c release` too.
    @Test func measureAHundredMegabytes() async throws {
        let data = Self.noise(100_000_000, seed: 15)
        let source = try file(data)
        let drive = device("standard chunks", .standard)
        let clock = ContinuousClock()
        var start = clock.now
        let node = try await drive.upload(source, as: "big.bin", in: nil)
        let upload = clock.now - start
        let out = directory.appendingPathComponent("out.bin")
        start = clock.now
        try await drive.download(node, to: out)
        let download = clock.now - start
        // Again, with the file itself as the previous copy: nothing to fetch.
        pds.resetCounts()
        start = clock.now
        try await drive.download(node, to: out, previous: out)
        let local = clock.now - start
        #expect(pds.downloads == 0)
        #expect(try Data(contentsOf: out) == data)
        let chunks = node.record.chunks?.count ?? 0
        print(
            "100 MB in \(chunks) chunks: upload \(upload), download \(download), "
                + "download from an identical local copy \(local)")
        try FileManager.default.removeItem(at: out)
        try FileManager.default.removeItem(at: source)
    }
}

import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// The drive as the PDS sees it: sealed records and encrypted chunks. What a device can't open
/// is unreadable, never a different file, and never taken for deleted.
@Suite struct EncryptionTests {
    let pds = FakePDS()
    let clock = TestClock(HistoryTests.start)
    let laptop: Drive
    let directory: URL

    init() async throws {
        let clock = clock
        laptop = pds.device("laptop", tids: TIDSource(clockID: 1) { clock.now })
        _ = try await laptop.create()
        directory = try temporaryDirectory()
    }

    func file(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func contents(_ node: Node, drive: Drive? = nil) async throws -> String {
        var data = Data()
        try await (drive ?? laptop).read(node) { data += $0 }
        return String(decoding: data, as: UTF8.self)
    }

    /// The keys a stored record has, outside its sealed value.
    func outerKeys(_ rkey: String, _ collection: String = Lexicon.node) throws -> Set<String> {
        Set(try #require(pds.rawRecord(rkey: rkey, collection: collection)).keys)
    }

    // MARK: Round trips

    @Test func nodeVersionAndSettingsRecordsRoundTrip() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        let created = try await laptop.upload(try file("hello, sealed world"), as: "a.txt", in: docs.id)
        clock.advance(60)
        let moved = try await laptop.move(created, to: nil, as: "b.txt")
        let snapshot = try await laptop.update(nil)

        #expect(snapshot.tree.nodes[docs.id]?.record == docs.record)
        #expect(snapshot.tree.nodes[moved.id]?.record == moved.record)
        #expect(snapshot.tree.unreadable.isEmpty && snapshot.history.unreadable.isEmpty)
        let versions = snapshot.history.versions(of: created.id)
        #expect(versions.map(\.record.change) == [.created, .moved])
        #expect(versions[0].record.chunks == created.record.chunks)
        #expect(snapshot.history.record(at: versions[1]) == moved.record)
        let settings = try #require(snapshot.settings)
        #expect(settings.retentionDays == 30 && settings.roster.map(\.name) == ["laptop"])
        #expect(try await contents(try #require(snapshot.tree.nodes[moved.id])) == "hello, sealed world")

        // Stored, each holds only its type, the blob refs, and the sealed value.
        #expect(try outerKeys(created.id) == ["$type", "chunks", "sealed"])
        #expect(try outerKeys(docs.id) == ["$type", "sealed"])
        #expect(try outerKeys(versions[0].id, Lexicon.version) == ["$type", "chunks", "sealed"])
        #expect(try outerKeys(versions[1].id, Lexicon.version) == ["$type", "sealed"])  // points to the first
        #expect(try outerKeys(Lexicon.settingsKey, Lexicon.settings) == ["$type", "sealed"])
        // And it survives being saved locally and loaded again.
        let saved = try #require(try snapshot.saved())
        let loaded = try #require(DriveSnapshot(saved: saved, drive: laptop))
        #expect(loaded.tree.nodes == snapshot.tree.nodes && loaded.settings == snapshot.settings)
    }

    @Test func chunksAreEncryptedWithTheFirstKey() async throws {
        let node = try await laptop.upload(try file("aaaabbbbcc"), as: "a.txt", in: nil)
        let first = try #require(laptop.keyring?.keys.first)
        let chunks = try #require(node.record.chunks)
        #expect(chunks.map(\.size) == [4, 4, 2])  // the contents' sizes; the blobs are 16 bytes longer
        for (chunk, piece) in zip(chunks, ["aaaa", "bbbb", "cc"]) {
            let expected = first.encryptChunk(Data(piece.utf8))
            #expect(chunk.id == expected.id)
            #expect(chunk.cid == CID.forBlob(expected.ciphertext))  // the CID covers the ciphertext
            #expect(chunk.blob.size == piece.utf8.count + 16)
            #expect(pds.blobs[chunk.cid] == expected.ciphertext)
        }
        #expect(try await contents(node) == "aaaabbbbcc")
    }

    /// Whoever runs the PDS sees neither names nor contents, nor the hashes that would let it
    /// confirm a file it already knows.
    @Test func thePDSLearnsNothing() async throws {
        let name = "tax-return-2026.pdf"
        let folder = "Very Private Folder"
        let text = "My social security number is 078-05-1120, and this is the whole file."
        // Big chunks, so unencrypted the whole file would be in one blob.
        let drive = pds.device("big chunks", chunkSize: 1 << 20, keyring: laptop.keyring)
        let parent = try await drive.createFolder(named: folder, in: nil)
        let node = try await drive.upload(try file(text), as: name, in: parent.id)
        let renamed = try await drive.move(node, to: parent.id, as: "renamed-" + name)
        try await drive.delete([renamed])
        let sha256 = try #require(node.record.sha256)
        #expect(sha256 == SHA256.hash(data: Data(text.utf8)).hexString)

        let secrets = [name, folder, text, sha256, sha256.uppercased(), "078-05-1120"].map { Data($0.utf8) }
        for stored in pds.everythingStored {
            for secret in secrets {
                #expect(stored.range(of: secret) == nil, "\(String(decoding: secret, as: UTF8.self)) is readable")
            }
        }
    }

    // MARK: Tampering

    @Test func aSealedValueMovedToAnotherRecordIsUnreadable() async throws {
        let a = try await laptop.upload(try file("aaaa"), as: "a.txt", in: nil)
        let b = try await laptop.upload(try file("bbbb"), as: "b.txt", in: nil)
        // The PDS puts a.txt's record where b.txt's is: it isn't a second a.txt, it's unreadable.
        pds.insertRawRecord(rkey: b.id, try #require(pds.rawRecord(rkey: a.id)))
        let tree = try await laptop.tree()
        #expect(tree.nodes.keys.sorted() == [a.id])
        #expect(tree.unreadable[b.id]?.reason == .tampered)

        // So does a version moved to another key.
        let snapshot = try await laptop.update(nil)
        let versions = snapshot.history.versions(of: a.id)
        let version = try #require(versions.first)
        pds.insertRawRecord(
            rkey: "3zzzzzzzzzzz2", collection: Lexicon.version,
            try #require(pds.rawRecord(rkey: version.id, collection: Lexicon.version)))
        let after = try await laptop.update(snapshot)
        #expect(after.history.unreadable["3zzzzzzzzzzz2"]?.reason == .tampered)
        #expect(after.history.versions(of: a.id) == versions)
    }

    @Test func aFlippedByteIsUnreadable() async throws {
        let a = try await laptop.upload(try file("aaaa"), as: "a.txt", in: nil)
        var record = try #require(pds.rawRecord(rkey: a.id))
        var sealed = try #require(record["sealed"] as? [String: Any])
        let encoded = (sealed["sealed"] as? [String: Any])?["$bytes"] as? String
        var bytes = try #require(encoded.flatMap(Base64.decode))
        bytes[bytes.startIndex + 20] ^= 0x01
        sealed["sealed"] = ["$bytes": Base64.encode(bytes)]
        record["sealed"] = sealed
        pds.insertRawRecord(rkey: a.id, record)
        var tree = try await laptop.tree()
        #expect(tree.nodes.isEmpty && tree.unreadable[a.id]?.reason == .tampered)

        // Blob refs that don't match the sealed chunk IDs: one dropped.
        let b = try await laptop.upload(try file("bbbbcccc"), as: "b.txt", in: nil)
        var shortened = try #require(pds.rawRecord(rkey: b.id))
        shortened["chunks"] = Array(try #require(shortened["chunks"] as? [Any]).prefix(1))
        pds.insertRawRecord(rkey: b.id, shortened)
        tree = try await laptop.tree()
        #expect(tree.unreadable[b.id]?.reason == .tampered)

        // A key ID changed: it's not sealed with any key this device has.
        let c = try await laptop.upload(try file("cccc"), as: "c.txt", in: nil)
        var renamedKey = try #require(pds.rawRecord(rkey: c.id))
        var sealedC = try #require(renamedKey["sealed"] as? [String: Any])
        sealedC["keyID"] = "0000000000000000"
        renamedKey["sealed"] = sealedC
        pds.insertRawRecord(rkey: c.id, renamedKey)
        tree = try await laptop.tree()
        #expect(tree.unreadable[c.id]?.reason == .missingKey)
    }

    @Test func aChunkSwappedOnTheServerFailsTheDownload() async throws {
        let a = try await laptop.upload(try file("aaaa"), as: "a.txt", in: nil)
        let b = try await laptop.upload(try file("bbbb"), as: "b.txt", in: nil)
        // b's blob ref under a's chunk ID: the CID matches what's served, but it doesn't decrypt.
        var record = try #require(pds.rawRecord(rkey: a.id))
        record["chunks"] = try #require(pds.rawRecord(rkey: b.id))["chunks"]
        pds.insertRawRecord(rkey: a.id, record)
        let swapped = try #require(try await laptop.tree().nodes[a.id])
        await #expect(throws: ATDriveError.self) { try await contents(swapped) }
    }

    // MARK: Without the key

    @Test func aDeviceWithoutTheKeySeesOnlyUnreadableRecords() async throws {
        let docs = try await laptop.createFolder(named: "docs", in: nil)
        try await laptop.upload(try file("aaaa"), as: "a.txt", in: docs.id)
        for stranger in [pds.device("no keys"), pds.device("another drive's keys", keyring: Keyring(DriveKey()))] {
            let snapshot = try await stranger.update(nil)
            #expect(snapshot.tree.nodes.isEmpty)
            #expect(snapshot.tree.unreadable.count == 2)
            #expect(snapshot.tree.unreadable.values.allSatisfy { $0.reason == .missingKey })
            #expect(snapshot.history.versions.isEmpty && snapshot.history.unreadable.count == 2)
            #expect(snapshot.settings == nil)
        }
        await #expect(throws: DriveAccessError.locked) {
            try await pds.device("no keys").createFolder(named: "x", in: nil)
        }
    }

    /// A record sealed with a key this device lacks (newer than its keyring, say) is held, not
    /// deleted, on both sides.
    @Test func syncHoldsWhatItCantOpen() async throws {
        let folder = try temporaryDirectory().appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("bee".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let log = Log()
        let sync = try FolderSync(folder: folder, drive: laptop, settle: 0) { log.add($0) }
        try await sync.sync()
        let tree = try await laptop.tree()
        let a = try #require(tree.child(named: "a.txt", in: nil))

        // a.txt is rewritten, sealed with a key this device doesn't have; and a new file too.
        let newer = Keyring(DriveKey())
        let payload: [String: Any] = ["name": "a.txt", "kind": "folder", "createdAt": "2026-11-09T00:00:00Z"]
        try pds.insertSealed(rkey: a.id, payload, keyring: newer)
        try pds.insertSealed(
            rkey: "3zzzzzzzzzzz2", ["name": "c.txt", "kind": "folder", "createdAt": "2026"], keyring: newer)
        try await sync.sync()

        let local = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".atdrive" }
        #expect(local.sorted() == ["a.txt", "b.txt"])
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "mine")
        #expect(pds.rawRecord(rkey: a.id) != nil && pds.rawRecord(rkey: "3zzzzzzzzzzz2") != nil)
        let unreadable = log.events.filter { $0.kind == .unreadable }
        #expect(unreadable.map(\.path).contains("/a.txt"))
        #expect(unreadable.allSatisfy { $0.description.contains("key") })

        // Deleting it here doesn't delete it there either: what can't be seen is left alone.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.txt"))
        try await sync.sync()
        #expect(pds.rawRecord(rkey: a.id) != nil)
    }

    // MARK: Settings

    /// The PDS (or anyone without the keys) can't set the retention: a plaintext or wrongly
    /// sealed settings record is ignored, and the default applies, so devices don't prune.
    @Test func forgedSettingsNeverMakeDevicesPrune() async throws {
        let a = try await laptop.upload(try file("v1"), as: "a.txt", in: nil)
        clock.advance(2 * HistoryTests.day)
        try await laptop.upload(try file("v2"), as: "a.txt", in: nil, replacing: a)
        clock.advance(3 * HistoryTests.day)

        let forgeries: [[String: Any]] = [
            ["$type": Lexicon.settings, "retentionDays": 1],
            try {
                let value = try laptop.stored(DriveSettings(retentionDays: 1), with: Keyring(DriveKey()))
                return try #require(try JSONSerialization.jsonObject(with: value.serialized()) as? [String: Any])
            }(),
        ]
        for forged in forgeries {
            pds.insertRawRecord(rkey: Lexicon.settingsKey, collection: Lexicon.settings, forged)
            let snapshot = try await laptop.update(nil)
            #expect(snapshot.settings == nil)
            #expect(snapshot.retention == DriveSettings().retention)
            #expect(try await laptop.prune(snapshot, now: clock.now) == 0)
            #expect(try await laptop.update(nil).history.versions(of: a.id).count == 2)
        }

        // Sealed by the drive, it's followed.
        let real = try laptop.stored(DriveSettings(retentionDays: 1), with: try #require(laptop.keyring))
        try await laptop.client.putSpaceRecord(
            space: laptop.space, repo: laptop.owner, collection: Lexicon.settings, rkey: Lexicon.settingsKey,
            record: real)
        let snapshot = try await laptop.update(nil)
        #expect(snapshot.settings?.retentionDays == 1)
        #expect(try await laptop.prune(snapshot, now: clock.now) == 1)
    }
}

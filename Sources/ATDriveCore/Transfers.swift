import Crypto
import Foundation

/// How a drive moves file contents: where files are cut into chunks, how many chunks move at
/// once, and how much of a chunk list one record holds.
public struct TransferOptions: Sendable, Equatable {
    /// Where chunk boundaries go. Every device writing to a drive must cut the same way
    /// (`.standard`): a file cut differently shares no chunks with what's already there.
    public var chunking: Chunker.Configuration
    /// How many chunks are uploaded, or downloaded, at once. Memory stays around twice this many
    /// of the biggest chunk: each in flight is held as plaintext and as ciphertext.
    public var parallel: Int
    /// The most bytes of chunk list (blob refs, and the chunks' IDs in the sealed part) one record
    /// holds, as stored. A longer list goes in `chunks` records of up to this much each
    /// (`Lexicon.chunks`).
    public var chunkListLimit: Int
    /// The most bytes of records one transaction (`applyWrites`) carries, as JSON. The reference
    /// PDS takes up to 1,000,000 bytes per request, so a node and its version, each with a chunk
    /// list as long as `chunkListLimit`, have to fit in it together.
    public var transactionLimit: Int

    public init(
        chunking: Chunker.Configuration = .standard, parallel: Int = 4, chunkListLimit: Int = 400_000,
        transactionLimit: Int = 900_000
    ) {
        precondition(parallel > 0 && chunkListLimit > 0 && transactionLimit > 0, "transfer limits must be positive")
        self.chunking = chunking
        self.parallel = parallel
        self.chunkListLimit = chunkListLimit
        self.transactionLimit = transactionLimit
    }

    public static let standard = TransferOptions()
}

/// Uploading and downloading file contents, a few chunks at a time.
extension Drive {
    /// The blobs' type: they're ciphertext.
    static let chunkType = "application/octet-stream"

    // MARK: Uploading

    /// A file's contents as stored: encrypted, in chunks the drive holds.
    struct StoredContents: Sendable {
        var chunks: [ChunkRef]
        var size: Int
        var sha256: String
        /// Chunks that weren't uploaded because a record in the drive already references them.
        var reused: Set<String>
        /// Chunks uploaded.
        var uploaded: Set<String>
    }

    private struct ChunkUpload: Sendable {
        enum Outcome: Sendable { case uploaded, reused, repeated }

        var index: Int
        var ref: ChunkRef
        var size: Int
        var outcome: Outcome
    }

    /// Cuts a file into chunks (where `transfers.chunking` says, seeded from the keyring's first
    /// key), encrypts each with the first key, and uploads those the drive doesn't have yet
    /// (`known`, by CID), `transfers.parallel` at a time.
    ///
    /// Chunk boundaries and IDs come from the first key, never the current one, so they stay the
    /// same when keys rotate. Encryption is deterministic (`DriveKey.encryptChunk`), so a chunk
    /// the drive already has encrypts to a blob it already has, and the CID says so before
    /// anything is sent.
    ///
    /// The file is read once, start to end, so memory stays at a few chunks whatever its size.
    func store(_ file: URL, known: Set<String>, progress: Progress?) async throws -> StoredContents {
        guard let key = keyring?.keys.first else { throw DriveAccessError.locked }
        let total = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let pieces = Chunker(configuration: transfers.chunking, seed: key.subkey(.chunkerSeed)).chunks(of: handle)
        let parallel = transfers.parallel
        // A chunk that comes up twice in one file is uploaded once.
        let claimed = Locked<Set<String>>([])

        var refs: [ChunkRef?] = []
        var hasher = SHA256()
        var done = 0
        var reused: Set<String> = []
        var uploaded: Set<String> = []
        progress?(0, total)
        try await withThrowingTaskGroup(of: ChunkUpload.self) { group in
            func finished(_ chunk: ChunkUpload) {
                refs[chunk.index] = chunk.ref
                switch chunk.outcome {
                case .uploaded: uploaded.insert(chunk.ref.cid)
                case .reused: reused.insert(chunk.ref.cid)
                case .repeated: break
                }
                done += chunk.size
                progress?(done, max(total, done))
            }
            var inFlight = 0
            for try await piece in pieces {
                hasher.update(data: piece)
                if inFlight == parallel, let chunk = try await group.next() {
                    finished(chunk)
                    inFlight -= 1
                }
                let index = refs.count
                refs.append(nil)
                group.addTask { try await self.upload(piece, index: index, key: key, known: known, claimed: claimed) }
                inFlight += 1
            }
            while let chunk = try await group.next() { finished(chunk) }
        }
        return StoredContents(
            chunks: refs.map { $0! }, size: done, sha256: hasher.finalize().hexString, reused: reused,
            uploaded: uploaded)
    }

    /// Encrypts one chunk and uploads it, unless the drive has it already (`known`) or another
    /// chunk of the same file is uploading it (`claimed`).
    private func upload(
        _ plaintext: Data, index: Int, key: DriveKey, known: Set<String>, claimed: Locked<Set<String>>
    ) async throws -> ChunkUpload {
        let chunk = key.encryptChunk(plaintext)
        let blob = BlobRef(cid: CID.forBlob(chunk.ciphertext), mimeType: Self.chunkType, size: chunk.ciphertext.count)
        if known.contains(blob.cid) {
            return ChunkUpload(
                index: index, ref: ChunkRef(blob: blob, id: chunk.id), size: plaintext.count, outcome: .reused)
        }
        guard claimed.update({ $0.insert(blob.cid).inserted }) else {
            return ChunkUpload(
                index: index, ref: ChunkRef(blob: blob, id: chunk.id), size: plaintext.count, outcome: .repeated)
        }
        let stored = try await client.uploadBlob(chunk.ciphertext, mimeType: Self.chunkType)
        guard stored.cid == blob.cid, stored.size == blob.size else {
            throw ATDriveError.integrity("the server stored a chunk as \(stored.cid), not \(blob.cid)")
        }
        return ChunkUpload(
            index: index, ref: ChunkRef(blob: stored, id: chunk.id), size: plaintext.count, outcome: .uploaded)
    }

    /// A blob a record referenced wasn't there: the write is refused. A chunk can go between
    /// deciding to reuse it and writing the record, when another device prunes or purges the
    /// last record that had it.
    static func isMissingBlob(_ error: Error) -> Bool {
        (error as? XRPCError)?.error == "BlobNotFound"
    }

    /// Progress that only ever moves forward, though what reports it may start over (an upload
    /// tried again).
    static func monotonic(_ progress: @escaping Progress) -> Progress {
        let reported = Locked(-1)
        return { done, total in
            let forward = reported.update { last in
                guard done > last else { return false }
                last = done
                return true
            }
            if forward { progress(done, total) }
        }
    }

    // MARK: Downloading

    /// Fetches a chunk and checks it: its CID, then that it decrypts with its ID.
    func fetch(_ chunk: ChunkRef, number: Int, of name: String) async throws -> Data {
        let ciphertext = try await client.getSpaceBlob(space: space, repo: owner, cid: chunk.cid)
        guard CID.forBlob(ciphertext) == chunk.cid else {
            throw ATDriveError.integrity("chunk \(chunk.cid) of \(name) doesn't match its CID")
        }
        do {
            return try chunk.id.decrypt(ciphertext)
        } catch {
            throw ATDriveError.integrity("chunk \(number) of \(name) doesn't decrypt")
        }
    }

    /// Hands a file's chunks to `write` in order: those `local` has from it, the rest fetched,
    /// `transfers.parallel` at a time. Fetched chunks wait, at most that many, until their turn.
    func readChunks(
        _ chunks: [ChunkRef], of name: String, local: LocalChunks?, write: (Data) throws -> Void
    ) async throws {
        let parallel = transfers.parallel
        let fetching = chunks.indices.filter { local?.has(chunks[$0].id) != true }
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var launched = 0
            var inFlight = 0
            var ready: [Int: Data] = [:]
            for (index, chunk) in chunks.enumerated() {
                while launched < fetching.count, inFlight + ready.count < parallel {
                    let next = fetching[launched]
                    let chunk = chunks[next]
                    group.addTask { (next, try await self.fetch(chunk, number: next + 1, of: name)) }
                    launched += 1
                    inFlight += 1
                }
                if let local, local.has(chunk.id) {
                    // Read back, and checked again: the local file may have changed since.
                    if let data = try local.read(chunk.id) {
                        try write(data)
                    } else {
                        try write(try await fetch(chunk, number: index + 1, of: name))
                    }
                    continue
                }
                while ready[index] == nil {
                    guard let (fetched, data) = try await group.next() else {
                        throw ATDriveError.integrity("chunk \(index + 1) of \(name) was never fetched")
                    }
                    inFlight -= 1
                    ready[fetched] = data
                }
                try write(ready.removeValue(forKey: index)!)
            }
        }
    }
}

extension DriveTree {
    /// The CIDs of the chunks current files use: chunks an upload needn't send again (see
    /// `Drive.upload`).
    public var chunkCIDs: Set<String> {
        var cids: Set<String> = []
        for node in nodes.values {
            for chunk in node.record.chunks ?? [] { cids.insert(chunk.cid) }
        }
        return cids
    }
}

extension DriveSnapshot {
    /// The CIDs of every chunk a record in the drive references: current files, history, and
    /// records this device can't read. The PDS keeps each while that record exists, so an upload
    /// needn't send it again (see `Drive.upload`).
    public var chunkCIDs: Set<String> {
        var cids = tree.chunkCIDs
        for version in history.versions.values {
            for chunk in version.record.chunks ?? [] { cids.insert(chunk.cid) }
        }
        let stored = tree.unreadable.values.map(\.value) + history.unreadable.values.map(\.value)
        for value in stored + continuations.values.map(Optional.some) {
            for blob in value?["chunks"]?.array ?? [] {
                if let cid = blob["ref"]?["$link"]?.string { cids.insert(cid) }
            }
        }
        return cids
    }
}

/// The chunks of a local file that a download can use instead of fetching them: a copy of an
/// older version, say. It's cut and named (`DriveKey.chunkID`) the way uploads are, with the
/// keyring's first key, so a chunk the two versions share has the same ID in both.
///
/// It keeps where each wanted chunk is in the file, not its bytes, and reads them back when
/// they're needed: memory stays small however big the file is.
final class LocalChunks {
    private let handle: FileHandle
    private let key: DriveKey
    private var ranges: [ChunkID: (offset: UInt64, count: Int)] = [:]

    /// Cuts `file` into chunks and keeps those in `wanted`. `nil` if there's none of them, or the
    /// file can't be read.
    init?(of file: URL, wanted: Set<ChunkID>, key: DriveKey, chunking: Chunker.Configuration) async {
        guard !wanted.isEmpty, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        self.handle = handle
        self.key = key
        var offset: UInt64 = 0
        do {
            let pieces = Chunker(configuration: chunking, seed: key.subkey(.chunkerSeed)).chunks(of: handle)
            for try await piece in pieces {
                let id = key.chunkID(for: piece)
                if wanted.contains(id), ranges[id] == nil { ranges[id] = (offset, piece.count) }
                offset += UInt64(piece.count)
            }
        } catch {
            ranges = [:]
        }
        if ranges.isEmpty { return nil }  // `deinit` closes the file
    }

    deinit { try? handle.close() }

    func has(_ id: ChunkID) -> Bool { ranges[id] != nil }

    /// The chunk's contents, if the file still has them where they were.
    func read(_ id: ChunkID) throws -> Data? {
        guard let range = ranges[id] else { return nil }
        try handle.seek(toOffset: range.offset)
        guard let data = try handle.read(upToCount: range.count), data.count == range.count,
            key.chunkID(for: data) == id
        else {
            ranges[id] = nil
            return nil
        }
        return data
    }

    /// How many of the chunks it found.
    var count: Int { ranges.count }
}

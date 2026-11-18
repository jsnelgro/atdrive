import Crypto
import Foundation
import Testing

@testable import ATDriveCore

@Suite struct ChunkerTests {
    /// Scaled down from the standard sizes, so tests see many chunks in little data.
    static let small = Chunker.Configuration(minSize: 4 << 10, averageSize: 16 << 10, maxSize: 64 << 10)
    static let seed = SymmetricKey(data: Data(0..<32))

    /// Deterministic pseudo-random bytes: SplitMix64, 8 little-endian bytes per step. Simple
    /// enough to write anywhere, so other platforms can check the same vectors.
    static func randomData(count: Int, seed: UInt64) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: count, by: 8) {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                withUnsafeBytes(of: z.littleEndian) { word in
                    let take = min(8, count - offset)
                    bytes.baseAddress!.advanced(by: offset).copyMemory(from: word.baseAddress!, byteCount: take)
                }
            }
        }
        return data
    }

    static func chunks(
        _ data: Data, _ configuration: Chunker.Configuration = small, seed: SymmetricKey? = nil, pieceSizes: [Int] = []
    ) -> [Data] {
        var chunker = Chunker(configuration: configuration, seed: seed)
        var chunks: [Data] = []
        var start = data.startIndex
        var piece = 0
        while start < data.endIndex {
            let size = pieceSizes.isEmpty ? data.count : pieceSizes[piece % pieceSizes.count]
            let end = min(start + size, data.endIndex)
            chunks += chunker.update(data[start..<end])
            start = end
            piece += 1
        }
        if let tail = chunker.finish() { chunks.append(tail) }
        return chunks
    }

    /// Where each chunk ends.
    static func ends(_ chunks: [Data]) -> [Int] {
        var offset = 0
        return chunks.map {
            offset += $0.count
            return offset
        }
    }

    // MARK: Fixed vectors
    // Computed by an independent, non-streaming implementation of the paper's algorithm (in
    // JavaScript, with Node's HKDF), and matched by this one. Changing any of these changes every
    // chunk a drive has stored.

    @Test func generator() {
        #expect(
            SHA256.hash(data: Self.randomData(count: 1 << 20, seed: 1)).hexString
                == "85b66b3a5816d686deb42f2d2473d9a7121ceb75c822b838f958c76ca86ed8ea")
    }

    @Test func smallVectors() {
        let data = Self.randomData(count: 1 << 20, seed: 1)
        #expect(
            Self.ends(Self.chunks(data)) == [
                13088, 23606, 41910, 61866, 78809, 99802, 122683, 143020, 147325, 166030, 176539, 195155, 215363,
                232055, 249812, 267923, 284532, 300036, 318251, 337003, 355150, 376760, 395679, 412435, 432300,
                458857, 478477, 502138, 522354, 529568, 549935, 566531, 585141, 604728, 613233, 633532, 653591,
                678865, 707753, 712672, 729251, 746590, 764567, 782528, 789637, 806550, 824095, 845777, 858606,
                875325, 891839, 909954, 929329, 949831, 970443, 989959, 1_008_004, 1_026_222, 1_045_020, 1_048_576,
            ])
        #expect(
            Self.ends(Self.chunks(data, seed: Self.seed)) == [
                16720, 38825, 56954, 78715, 85307, 113194, 133936, 154337, 160533, 179074, 194862, 221412, 241938,
                249850, 269359, 289739, 309257, 327231, 345560, 362370, 380268, 399554, 417143, 436445, 456488,
                474873, 501475, 519524, 531295, 561911, 567792, 594003, 619464, 639083, 667681, 685448, 704654,
                721945, 739108, 751772, 766972, 784173, 801511, 820939, 830015, 847019, 868555, 885121, 903892,
                920964, 942612, 954253, 983809, 1_000_810, 1_023_662, 1_048_576,
            ])
    }

    @Test func standardVectors() {
        let data = Self.randomData(count: 12 << 20, seed: 2)
        #expect(SHA256.hash(data: data).hexString == "7a813788ca067c6d24cf106c6b5701c1f8a512dc98cbae3fb4de61006af8c31f")
        #expect(
            Self.ends(Self.chunks(data, .standard)) == [
                1_196_198, 2_216_584, 2_961_871, 4_160_115, 5_268_486, 6_355_436, 7_537_049, 8_670_250, 10_186_939,
                11_530_221, 12_582_912,
            ])
        #expect(
            Self.ends(Self.chunks(data, .standard, seed: Self.seed)) == [
                533_673, 1_762_717, 2_882_811, 4_601_456, 5_656_921, 6_854_423, 7_908_927, 9_630_426, 11_045_813,
                12_214_388, 12_582_912,
            ])
    }

    // MARK: Properties

    @Test func sizesStayInBounds() {
        let data = Self.randomData(count: 2 << 20, seed: 3)
        let chunks = Self.chunks(data)
        for chunk in chunks.dropLast() {
            #expect((4 << 10)...(64 << 10) ~= chunk.count)
        }
        #expect((1...(64 << 10)) ~= chunks.last!.count)

        // Data with no boundaries in it is cut at the maximum.
        let zeros = Self.chunks(Data(count: 200 << 10))
        #expect(zeros.map(\.count) == [64 << 10, 64 << 10, 64 << 10, 8 << 10])
        // Less than the minimum is one chunk; nothing is no chunks.
        #expect(Self.chunks(Data(count: 1000)).map(\.count) == [1000])
        #expect(Self.chunks(Data()).isEmpty)
    }

    @Test func chunksReassembleTheInput() {
        let data = Self.randomData(count: 1 << 20, seed: 4)
        let chunks = Self.chunks(data, pieceSizes: [100_000])
        #expect(chunks.count > 30)
        #expect(chunks.reduce(Data(), +) == data)
        #expect(chunks.allSatisfy { $0.startIndex == 0 })
    }

    @Test func deterministic() {
        let data = Self.randomData(count: 1 << 20, seed: 5)
        #expect(Self.chunks(data) == Self.chunks(data))
        // A chunker can be reused after `finish()`.
        var chunker = Chunker(configuration: Self.small)
        for _ in 0..<2 {
            var chunks = chunker.update(data)
            chunks += chunker.finish().map { [$0] } ?? []
            #expect(chunks == Self.chunks(data))
        }
    }

    @Test func seedsChangeBoundaries() {
        let data = Self.randomData(count: 1 << 20, seed: 6)
        let seeded = Self.ends(Self.chunks(data, seed: Self.seed))
        #expect(Self.ends(Self.chunks(data, seed: SymmetricKey(data: Data(0..<32)))) == seeded)
        let other = Self.ends(Self.chunks(data, seed: SymmetricKey(data: Data(1...32))))
        let unseeded = Self.ends(Self.chunks(data))
        #expect(other != seeded)
        #expect(unseeded != seeded)
        // Almost no boundary in common, not just a shifted one.
        #expect(Set(other).intersection(seeded).count < 5)
    }

    /// The point of content-defined chunking: an edit near the start changes only the chunks
    /// around it.
    @Test func insertingAByteKeepsLaterChunks() {
        let data = Self.randomData(count: 2 << 20, seed: 7)
        var edited = data
        edited.insert(0x42, at: 1000)
        let original = Set(Self.chunks(data))
        let after = Self.chunks(edited)
        let changed = after.filter { !original.contains($0) }
        #expect(after.count > 100)
        #expect(changed.count <= 2)
        #expect(changed.first == after.first)
    }

    @Test func piecesDontMoveBoundaries() {
        let data = Self.randomData(count: 1 << 20, seed: 8)
        let whole = Self.chunks(data)
        for pieces in [[7, 4093, 65537], [4096], [65536], [1 << 20], [3, 1 << 20]] {
            #expect(Self.chunks(data, pieceSizes: pieces) == whole, "pieces of \(pieces)")
        }
        // Byte by byte on a shorter input; boundaries land exactly on piece edges, too.
        let short = data.prefix(200_000)
        #expect(Self.chunks(short, pieceSizes: [1]) == Self.chunks(short))
        let ends = Self.ends(Self.chunks(short))
        var sizes: [Int] = []
        var last = 0
        for end in ends {
            sizes.append(end - last)
            last = end
        }
        #expect(Self.chunks(short, pieceSizes: sizes) == Self.chunks(short))
        // Pieces that are slices of a bigger Data.
        #expect(Self.chunks(data[1000...]) == Self.chunks(Data(data[1000...])))
    }

    @Test func chunksAFile() async throws {
        let data = Self.randomData(count: 1 << 20, seed: 9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunker-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var chunks: [Data] = []
        for try await chunk in try Chunker(configuration: Self.small).chunks(ofFileAt: url, readSize: 10_000) {
            chunks.append(chunk)
        }
        #expect(chunks == Self.chunks(data))

        let empty = url.appendingPathExtension("empty")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        var count = 0
        for try await _ in try Chunker().chunks(ofFileAt: empty) { count += 1 }
        #expect(count == 0)
    }

    /// Prints throughput and the average chunk size. Asserts nothing about speed, so a slow
    /// machine (or a debug build) can't fail it.
    @Test func throughput() {
        let data = Self.randomData(count: 64 << 20, seed: 10)
        var chunker = Chunker()
        var chunks: [Data] = []
        let elapsed = ContinuousClock().measure {
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + (4 << 20), data.endIndex)
                chunks += chunker.update(data[start..<end])
                start = end
            }
            if let tail = chunker.finish() { chunks.append(tail) }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let average = Double(data.count) / Double(chunks.count) / Double(1 << 20)
        print(
            "Chunker: \(Int(Double(data.count) / seconds / 1e6)) MB/s, \(chunks.count) chunks averaging \(average) MiB")
        #expect((0.75...1.5) ~= average)
    }
}

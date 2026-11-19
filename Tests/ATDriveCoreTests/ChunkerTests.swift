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
    // JavaScript, with Node's HKDF), and matched by this one; `Tests/vectors/chunker_vectors.py`
    // reproduces them too. Changing any of these changes every chunk a drive has stored.

    @Test func generator() {
        #expect(
            SHA256.hash(data: Self.randomData(count: 1 << 20, seed: 1)).hexString
                == "85b66b3a5816d686deb42f2d2473d9a7121ceb75c822b838f958c76ca86ed8ea")
    }

    @Test func smallVectors() {
        let data = Self.randomData(count: 1 << 20, seed: 1)
        #expect(
            Self.ends(Self.chunks(data)) == [
                17625, 36711, 49565, 54085, 73438, 90577, 116233, 139958, 144429, 164126, 177031, 204282, 222222,
                244041, 260493, 269508, 287552, 304091, 321080, 337885, 354985, 371273, 388320, 408359, 425445, 456093,
                475613, 490659, 511077, 531788, 550076, 568279, 588904, 610041, 630878, 646748, 665917, 676521, 694787,
                712379, 717854, 745817, 756944, 774158, 802414, 827137, 835280, 852402, 860889, 881600, 899593, 916141,
                937563, 954901, 975125, 991674, 1_010_969, 1_027_788, 1_044_278, 1_048_576,
            ])
        #expect(
            Self.ends(Self.chunks(data, seed: Self.seed)) == [
                23119, 44960, 68870, 87538, 100073, 126367, 148999, 166412, 191376, 198678, 222045, 243411, 263909,
                278780, 295644, 309764, 335027, 351604, 373494, 390151, 407301, 425156, 443875, 463711, 486940, 497488,
                522508, 541330, 561066, 573214, 582001, 595203, 621916, 646435, 664703, 681707, 700126, 717732, 734673,
                742912, 771134, 794376, 814403, 832279, 852464, 869082, 885517, 889621, 906877, 923573, 940895, 965337,
                969603, 977062, 999444, 1_015_428, 1_040_890, 1_048_576,
            ])
    }

    @Test func standardVectors() {
        let data = Self.randomData(count: 12 << 20, seed: 2)
        #expect(SHA256.hash(data: data).hexString == "7a813788ca067c6d24cf106c6b5701c1f8a512dc98cbae3fb4de61006af8c31f")
        #expect(
            Self.ends(Self.chunks(data, .standard)) == [
                1_173_155, 2_258_986, 3_315_429, 4_418_968, 5_587_405, 5_921_319, 7_231_542, 8_759_605, 9_654_784,
                11_478_853, 12_571_490, 12_582_912,
            ])
        #expect(
            Self.ends(Self.chunks(data, .standard, seed: Self.seed)) == [
                1_055_574, 2_142_288, 3_241_877, 4_152_814, 4_469_648, 5_874_977, 7_234_794, 8_365_628, 9_614_273,
                10_248_518, 11_782_884, 12_582_912,
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

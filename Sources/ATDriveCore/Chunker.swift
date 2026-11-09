import Crypto
import Foundation

/// Content-defined chunking: FastCDC (Xia et al., "FastCDC: a Fast and Efficient Content-Defined
/// Chunking Approach", USENIX ATC 2016), with normalized chunking at level 2.
///
/// Boundaries follow the content, so an insert or delete changes the chunks around it rather than
/// every chunk after it, and a new version of a file costs only the chunks that changed.
///
/// Feed a stream to `update(_:)` and end it with `finish()`. The boundaries don't depend on how
/// the stream is split into pieces. They do depend on the configuration and the seed, so every
/// device writing a drive must use the same ones.
public struct Chunker: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var minSize: Int
        /// A power of two.
        public var averageSize: Int
        public var maxSize: Int

        /// What the drive uses. The maximum stays under self-hosted PDSes' 5 MB blob limit.
        public static let standard = Configuration(minSize: 256 << 10, averageSize: 1 << 20, maxSize: 4 << 20)

        public init(minSize: Int, averageSize: Int, maxSize: Int) {
            precondition(0 < minSize && minSize <= averageSize && averageSize <= maxSize, "chunk sizes out of order")
            precondition(
                averageSize.nonzeroBitCount == 1 && averageSize >= 8, "average chunk size isn't a power of two, 8 or more")
            self.minSize = minSize
            self.averageSize = averageSize
            self.maxSize = maxSize
        }
    }

    public let configuration: Configuration
    /// One random 64-bit value per byte value, for the gear hash.
    private let gear: [UInt64]
    /// The hash ends a chunk when these bits are all zero. Below the average size it takes
    /// `log2(average) + 2` zero bits, above it `log2(average) - 2`: chunks shorter or longer than
    /// average get rarer, which is what normalized chunking does. The bits are the hash's top ones,
    /// which cover the most input: each byte shifts the hash left by one, so bit k depends on the
    /// last k + 1 bytes.
    private let smallMask: UInt64
    private let largeMask: UInt64

    /// The current chunk's bytes, until its end is found.
    private var pending = Data()
    private var length = 0
    private var hash: UInt64 = 0

    /// - Parameter seed: 32 secret bytes that pick the gear table, so chunk boundaries (and so
    ///   chunk sizes) don't reveal which known file a drive holds. No seed means a fixed table.
    public init(configuration: Configuration = .standard, seed: SymmetricKey? = nil) {
        precondition(seed.map { $0.bitCount == 256 } ?? true, "a chunker seed is 32 bytes")
        self.configuration = configuration
        let bits = configuration.averageSize.trailingZeroBitCount
        smallMask = UInt64.max << (64 - min(bits + 2, 64))
        largeMask = UInt64.max << (64 - max(bits - 2, 1))
        let table = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: seed ?? SymmetricKey(data: Data(count: 32)),
            info: Data("me.jsnelgro.atdrive chunker gear table".utf8), outputByteCount: 256 * 8)
        gear = table.withUnsafeBytes { bytes in
            (0..<256).map { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8 * $0, as: UInt64.self)) }
        }
    }

    /// Adds the next piece of the stream and returns the chunks it completes, in order.
    public mutating func update(_ data: Data) -> [Data] {
        let ends = data.withUnsafeBytes { findEnds(in: $0) }
        var chunks: [Data] = []
        var start = data.startIndex
        for end in ends {
            pending.append(data[start..<data.startIndex + end])
            chunks.append(pending)
            pending = Data()
            start = data.startIndex + end
        }
        pending.append(data[start...])
        return chunks
    }

    /// Ends the stream and returns its last chunk, if any bytes are left. The chunker can then
    /// start on another stream.
    public mutating func finish() -> Data? {
        defer {
            pending = Data()
            length = 0
            hash = 0
        }
        return pending.isEmpty ? nil : pending
    }

    /// The offsets in `bytes` where chunks end, continuing the current chunk. A chunk ends before
    /// the byte whose hash matches (as in the paper), or at the maximum size. Hashing starts at the
    /// minimum size: the bytes before it can't end a chunk, so they're skipped.
    private mutating func findEnds(in bytes: UnsafeRawBufferPointer) -> [Int] {
        let (minSize, normalSize, maxSize) = (configuration.minSize, configuration.averageSize, configuration.maxSize)
        let (smallMask, largeMask) = (self.smallMask, self.largeMask)
        var ends: [Int] = []
        var length = self.length
        var hash = self.hash
        var index = 0
        let count = bytes.count
        gear.withUnsafeBufferPointer { gear in
            while index < count {
                if length < minSize {
                    let skip = min(minSize - length, count - index)
                    index += skip
                    length += skip
                    continue
                }
                var found = false
                while index < count && length < normalSize {
                    hash = (hash &<< 1) &+ gear[Int(bytes[index])]
                    if hash & smallMask == 0 {
                        found = true
                        break
                    }
                    index += 1
                    length += 1
                }
                while !found && index < count && length < maxSize {
                    hash = (hash &<< 1) &+ gear[Int(bytes[index])]
                    if hash & largeMask == 0 {
                        found = true
                        break
                    }
                    index += 1
                    length += 1
                }
                if found || length == maxSize {
                    ends.append(index)
                    length = 0
                    hash = 0
                }
            }
        }
        self.length = length
        self.hash = hash
        return ends
    }
}

extension Chunker {
    /// The chunks of the rest of a file, continuing from this chunker (normally a new one). Reads
    /// `readSize` bytes at a time, so memory stays around a few chunks whatever the file's size.
    /// Reads block, like the rest of the drive's file I/O.
    public func chunks(of handle: FileHandle, readSize: Int = 1 << 20) -> FileChunks {
        FileChunks(handle: handle, chunker: self, readSize: readSize)
    }

    public func chunks(ofFileAt url: URL, readSize: Int = 1 << 20) throws -> FileChunks {
        chunks(of: try FileHandle(forReadingFrom: url), readSize: readSize)
    }

    public struct FileChunks: AsyncSequence {
        public typealias Element = Data

        let handle: FileHandle
        let chunker: Chunker
        let readSize: Int

        public func makeAsyncIterator() -> Iterator {
            Iterator(handle: handle, chunker: chunker, readSize: readSize)
        }

        public struct Iterator: AsyncIteratorProtocol {
            let handle: FileHandle
            var chunker: Chunker
            let readSize: Int
            /// Chunks found but not yet returned, last first.
            var ready: [Data] = []
            var finished = false

            public mutating func next() async throws -> Data? {
                while true {
                    if let chunk = ready.popLast() { return chunk }
                    if finished { return nil }
                    if let data = try handle.read(upToCount: readSize), !data.isEmpty {
                        ready = chunker.update(data).reversed()
                    } else {
                        finished = true
                        ready = chunker.finish().map { [$0] } ?? []
                    }
                }
            }
        }
    }
}

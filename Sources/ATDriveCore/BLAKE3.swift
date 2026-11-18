/// BLAKE3, with extendable output. swift-crypto doesn't have it, and a space's commit hashes its
/// records with it (see `LtHash`). A port of the spec's reference implementation
/// (https://github.com/BLAKE3-team/BLAKE3), one chunk at a time, without the official crate's
/// parallel paths: it mostly hashes short strings, so reasonably fast is enough. No dependencies,
/// so it runs anywhere.
public struct BLAKE3: Sendable {
    /// The default output length, in bytes.
    public static let byteCount = 32

    private let key: SIMD8<UInt32>
    private let flags: UInt32
    private var chunk: ChunkState
    /// Chaining values of completed subtrees, largest first: one per 1 bit of the chunk count.
    private var stack: [SIMD8<UInt32>] = []

    /// Plain hashing.
    public init() {
        self.init(key: iv, flags: 0)
    }

    /// Keyed hashing (a MAC or PRF). The key is 32 bytes.
    public init(key: some Collection<UInt8>) {
        precondition(key.count == 32, "a BLAKE3 key is 32 bytes")
        self.init(key: Array(key).withUnsafeBytes(loadKey), flags: Flag.keyedHash)
    }

    /// Key derivation: hash key material with this, under a hardcoded, globally unique context
    /// string (e.g. "example.com 2026-11-09 session tokens").
    public init(derivingKeyFromContext context: String) {
        var hasher = BLAKE3(key: iv, flags: Flag.deriveKeyContext)
        hasher.update(Array(context.utf8))
        self.init(key: hasher.finalize().withUnsafeBytes(loadKey), flags: Flag.deriveKeyMaterial)
    }

    private init(key: SIMD8<UInt32>, flags: UInt32) {
        self.key = key
        self.flags = flags
        chunk = ChunkState(key: key, counter: 0, flags: flags)
    }

    /// The hash of `data`, `byteCount` bytes long.
    public static func hash(_ data: some Sequence<UInt8>, byteCount: Int = BLAKE3.byteCount) -> [UInt8] {
        var hasher = BLAKE3()
        hasher.update(data)
        return hasher.finalize(byteCount: byteCount)
    }

    public mutating func update(_ data: some Sequence<UInt8>) {
        let handled: Void? = data.withContiguousStorageIfAvailable { update(bufferPointer: UnsafeRawBufferPointer($0)) }
        if handled == nil { Array(data).withUnsafeBytes { update(bufferPointer: $0) } }
    }

    public mutating func update(bufferPointer bytes: UnsafeRawBufferPointer) {
        var input = bytes
        while !input.isEmpty {
            // A full chunk is finished only once more input arrives: the last one is the root's.
            if chunk.length == chunkLength {
                let total = chunk.counter + 1
                push(chunk.output.chainingValue, totalChunks: total)
                chunk = ChunkState(key: key, counter: total, flags: flags)
            }
            let take = min(chunkLength - chunk.length, input.count)
            chunk.update(UnsafeRawBufferPointer(rebasing: input[..<take]))
            input = UnsafeRawBufferPointer(rebasing: input[take...])
        }
    }

    /// The hash of everything so far, `byteCount` bytes long. Longer outputs extend shorter ones.
    public func finalize(byteCount: Int = BLAKE3.byteCount) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: byteCount) { buffer, count in
            finalize(into: UnsafeMutableRawBufferPointer(buffer))
            count = byteCount
        }
    }

    /// Fills `output` with the hash of everything so far.
    public func finalize(into output: UnsafeMutableRawBufferPointer) {
        var node = chunk.output
        for left in stack.reversed() {
            node = Output(
                cv: key, block: SIMD16(lowHalf: left, highHalf: node.chainingValue), counter: 0,
                blockLength: UInt32(blockLength), flags: flags | Flag.parent)
        }
        node.root(into: output)
    }

    /// Adds a finished chunk's chaining value, merging every subtree it completes (one per
    /// trailing 0 bit of the new chunk count).
    private mutating func push(_ chainingValue: SIMD8<UInt32>, totalChunks: UInt64) {
        var cv = chainingValue
        var total = totalChunks
        while total & 1 == 0 {
            cv =
                Output(
                    cv: key, block: SIMD16(lowHalf: stack.removeLast(), highHalf: cv), counter: 0,
                    blockLength: UInt32(blockLength), flags: flags | Flag.parent
                ).chainingValue
            total >>= 1
        }
        stack.append(cv)
    }
}

private let chunkLength = 1024
private let blockLength = 64

private let iv = SIMD8<UInt32>(
    0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19)

private enum Flag {
    static let chunkStart: UInt32 = 1 << 0
    static let chunkEnd: UInt32 = 1 << 1
    static let parent: UInt32 = 1 << 2
    static let root: UInt32 = 1 << 3
    static let keyedHash: UInt32 = 1 << 4
    static let deriveKeyContext: UInt32 = 1 << 5
    static let deriveKeyMaterial: UInt32 = 1 << 6
}

/// The chunk being hashed: up to 16 blocks, the last of which is held back until we know whether
/// it ends the chunk.
private struct ChunkState: Sendable {
    var cv: SIMD8<UInt32>
    let counter: UInt64
    let flags: UInt32
    var block = SIMD64<UInt8>()
    var blockFill = 0
    var blocksCompressed = 0

    init(key: SIMD8<UInt32>, counter: UInt64, flags: UInt32) {
        cv = key
        self.counter = counter
        self.flags = flags
    }

    var length: Int { blocksCompressed * blockLength + blockFill }

    private var startFlag: UInt32 { blocksCompressed == 0 ? Flag.chunkStart : 0 }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var input = bytes
        while !input.isEmpty {
            if blockFill == blockLength {
                let words = withUnsafeBytes(of: block) { loadWords($0.baseAddress!) }
                compressBlock(words)
                block = SIMD64()
                blockFill = 0
            }
            // Whole blocks with more input after them aren't the chunk's last: compress them in
            // place instead of copying them into `block`.
            while blockFill == 0 && input.count > blockLength {
                compressBlock(loadWords(input.baseAddress!))
                input = UnsafeRawBufferPointer(rebasing: input[blockLength...])
            }
            let take = min(blockLength - blockFill, input.count)
            let fill = blockFill
            withUnsafeMutableBytes(of: &block) { block in
                block.baseAddress!.advanced(by: fill).copyMemory(from: input.baseAddress!, byteCount: take)
            }
            blockFill += take
            input = UnsafeRawBufferPointer(rebasing: input[take...])
        }
    }

    private mutating func compressBlock(_ words: SIMD16<UInt32>) {
        cv = compress(cv, words, counter, UInt32(blockLength), flags | startFlag).lowHalf
        blocksCompressed += 1
    }

    var output: Output {
        Output(
            cv: cv, block: withUnsafeBytes(of: block) { loadWords($0.baseAddress!) }, counter: counter,
            blockLength: UInt32(blockFill), flags: flags | startFlag | Flag.chunkEnd)
    }
}

/// A compression not yet run: either a node's chaining value, or, with the root flag, the output.
private struct Output {
    var cv: SIMD8<UInt32>
    var block: SIMD16<UInt32>
    var counter: UInt64
    var blockLength: UInt32
    var flags: UInt32

    var chainingValue: SIMD8<UInt32> { compress(cv, block, counter, blockLength, flags).lowHalf }

    /// Extendable output: each 64 bytes is the root compression with the next counter.
    func root(into output: UnsafeMutableRawBufferPointer) {
        var offset = 0
        var counter: UInt64 = 0
        while offset < output.count {
            let words = compress(cv, block, counter, blockLength, flags | Flag.root)
            var bytes = SIMD16<UInt32>()
            for i in 0..<16 { bytes[i] = words[i].littleEndian }
            let take = min(64, output.count - offset)
            withUnsafeBytes(of: bytes) { bytes in
                output.baseAddress!.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: take)
            }
            offset += take
            counter += 1
        }
    }
}

/// A key's eight little-endian words, from 32 bytes.
private func loadKey(_ bytes: UnsafeRawBufferPointer) -> SIMD8<UInt32> {
    precondition(bytes.count == 32)
    var words = SIMD8<UInt32>()
    for i in 0..<8 {
        words[i] = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
    }
    return words
}

/// Sixteen little-endian words from 64 bytes.
@inline(__always)
private func loadWords(_ bytes: UnsafeRawPointer) -> SIMD16<UInt32> {
    var words = SIMD16<UInt32>()
    for i in 0..<16 {
        words[i] = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
    }
    return words
}

/// The compression function: 7 rounds over the 16-word state. In locals rather than an array so
/// it stays in registers.
private func compress(
    _ cv: SIMD8<UInt32>, _ block: SIMD16<UInt32>, _ counter: UInt64, _ blockLength: UInt32, _ flags: UInt32
) -> SIMD16<UInt32> {
    var v0 = cv[0]
    var v1 = cv[1]
    var v2 = cv[2]
    var v3 = cv[3]
    var v4 = cv[4]
    var v5 = cv[5]
    var v6 = cv[6]
    var v7 = cv[7]
    var v8 = iv[0]
    var v9 = iv[1]
    var v10 = iv[2]
    var v11 = iv[3]
    var v12 = UInt32(truncatingIfNeeded: counter)
    var v13 = UInt32(truncatingIfNeeded: counter >> 32)
    var v14 = blockLength
    var v15 = flags
    var m0 = block[0]
    var m1 = block[1]
    var m2 = block[2]
    var m3 = block[3]
    var m4 = block[4]
    var m5 = block[5]
    var m6 = block[6]
    var m7 = block[7]
    var m8 = block[8]
    var m9 = block[9]
    var m10 = block[10]
    var m11 = block[11]
    var m12 = block[12]
    var m13 = block[13]
    var m14 = block[14]
    var m15 = block[15]
    for round in 0..<7 {
        // Columns, then diagonals.
        g(&v0, &v4, &v8, &v12, m0, m1)
        g(&v1, &v5, &v9, &v13, m2, m3)
        g(&v2, &v6, &v10, &v14, m4, m5)
        g(&v3, &v7, &v11, &v15, m6, m7)
        g(&v0, &v5, &v10, &v15, m8, m9)
        g(&v1, &v6, &v11, &v12, m10, m11)
        g(&v2, &v7, &v8, &v13, m12, m13)
        g(&v3, &v4, &v9, &v14, m14, m15)
        if round < 6 {
            // The message permutation: 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8.
            (m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15) =
                (m2, m6, m3, m10, m7, m0, m4, m13, m1, m11, m12, m5, m9, m14, m15, m8)
        }
    }
    return SIMD16(
        v0 ^ v8, v1 ^ v9, v2 ^ v10, v3 ^ v11, v4 ^ v12, v5 ^ v13, v6 ^ v14, v7 ^ v15,
        v8 ^ cv[0], v9 ^ cv[1], v10 ^ cv[2], v11 ^ cv[3], v12 ^ cv[4], v13 ^ cv[5], v14 ^ cv[6], v15 ^ cv[7])
}

@inline(__always)
private func g(
    _ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32, _ x: UInt32, _ y: UInt32
) {
    a = a &+ b &+ x
    d = rotateRight(d ^ a, 16)
    c = c &+ d
    b = rotateRight(b ^ c, 12)
    a = a &+ b &+ y
    d = rotateRight(d ^ a, 8)
    c = c &+ d
    b = rotateRight(b ^ c, 7)
}

@inline(__always)
private func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 { (x &>> n) | (x &<< (32 &- n)) }

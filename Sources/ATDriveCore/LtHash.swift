import Crypto
import Foundation

/// The set hash a space's commit is built on, as in the reference (`lthash.ts` in
/// `packages/space`). Each element expands with BLAKE3 to 1024 16-bit lanes, which are added to the
/// state mod 2^16. Adding and removing commute, so the state depends only on which elements are in
/// the set, and keeping it current costs the same however big the set gets.
public struct LtHash: Sendable, Equatable {
    /// The state: 1024 little-endian `UInt16` lanes.
    public static let stateByteCount = 2048
    private static let laneCount = stateByteCount / 2

    private var lanes: [UInt16]

    /// The empty set.
    public init() {
        lanes = Array(repeating: 0, count: Self.laneCount)
    }

    /// A state saved from `state`. Nil unless it's 2048 bytes.
    public init?(state: Data) {
        guard state.count == Self.stateByteCount else { return nil }
        lanes = state.withUnsafeBytes { bytes in
            (0..<Self.laneCount).map {
                UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self))
            }
        }
    }

    /// The full state, for saving: the digest alone can't be updated.
    public var state: Data {
        var data = Data(count: Self.stateByteCount)
        data.withUnsafeMutableBytes { bytes in
            for (index, lane) in lanes.enumerated() {
                bytes.storeBytes(of: lane.littleEndian, toByteOffset: 2 * index, as: UInt16.self)
            }
        }
        return data
    }

    /// SHA-256 of the state: what a commit's `data` holds.
    public var digest: Data { Data(SHA256.hash(data: state)) }

    public var isEmpty: Bool { lanes.allSatisfy { $0 == 0 } }

    public mutating func add(_ element: String) { combine(element, &+) }

    /// Removes an element. Removing one that isn't in the set leaves the state as if it had a
    /// negative count, which adding it back cancels.
    public mutating func remove(_ element: String) { combine(element, &-) }

    private mutating func combine(_ element: String, _ operation: (UInt16, UInt16) -> UInt16) {
        var hasher = BLAKE3()
        hasher.update(element.utf8)
        withUnsafeTemporaryAllocation(byteCount: Self.stateByteCount, alignment: 2) { expanded in
            hasher.finalize(into: expanded)
            lanes.withUnsafeMutableBufferPointer { lanes in
                for index in 0..<Self.laneCount {
                    let lane = expanded.loadUnaligned(fromByteOffset: 2 * index, as: UInt16.self)
                    lanes[index] = operation(lanes[index], UInt16(littleEndian: lane))
                }
            }
        }
    }
}

/// A repo's records as its commit hashes them (the reference's `RepoCommit`), to check a copy of
/// the repo against `commit.data`. Every record in the repo counts, in every collection: leave
/// one out, or hold an old CID for it, and nothing matches.
public struct RepoSetHash: Sendable, Equatable {
    public var setHash: LtHash

    public init(setHash: LtHash = LtHash()) {
        self.setHash = setHash
    }

    /// A record's element: `<collection>/<rkey>/<cid>`, with the CID as the server writes it
    /// (base32, `bafy…`).
    public static func element(collection: String, rkey: String, cid: String) -> String {
        "\(collection)/\(rkey)/\(cid)"
    }

    public mutating func add(collection: String, rkey: String, cid: String) {
        setHash.add(Self.element(collection: collection, rkey: rkey, cid: cid))
    }

    public mutating func remove(collection: String, rkey: String, cid: String) {
        setHash.remove(Self.element(collection: collection, rkey: rkey, cid: cid))
    }

    /// Applies one write from the change feed (`listRepoOps`): `prev` is the CID it replaced (nil
    /// for a create) and `cid` the new one (nil for a delete).
    public mutating func applyOp(collection: String, rkey: String, prev: String?, cid: String?) {
        if let prev { remove(collection: collection, rkey: rkey, cid: prev) }
        if let cid { add(collection: collection, rkey: rkey, cid: cid) }
    }

    /// Whether these are the records the commit hashed. It says nothing about whether the commit
    /// is genuine: that's the server's word (or, for a space credential, its MAC's).
    public func matches(commitData: Data) -> Bool {
        setHash.digest == commitData
    }
}

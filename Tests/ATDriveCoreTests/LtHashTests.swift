import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// Expected digests come from running the reference algorithm (`lthash.ts`, `repo-commit.ts` and
/// `util.ts` in `packages/space` on permissioned-data-alpha) in Node with @noble/hashes 1.6.1.
/// `Tests/vectors/lthash_vectors.py` reproduces them independently (it needs the `blake3` package).
@Suite struct LtHashTests {
    static let node = "app.atdrive.node"
    static let version = "app.atdrive.version"
    static let records = [
        (node, "3m5xkq2v7ra2c", "bafyreib5xi33wcdr5xx3sw3gkuji3pqzejjc6f56btiqrhxx3vc4tow42e"),
        (node, "3m5xkq2wdcs2c", "bafyreicv6ocy5g7tbbs2a2meuypkjz6a6b4fjhgrcbvbcka2wop7rtlyae"),
        (version, "3m5xkq2wdcs2d", "bafyreidtelq4he57fx75pqqekctliinynajyq2lll6xojzosdtzngwhlla"),
    ]
    static let edited = "bafyreihe7fzvofj5dhrno6floqztkgxgl3rujlvr33hwjrj7b67jh32w64"

    func repo(adding indices: [Int]) -> RepoSetHash {
        var repo = RepoSetHash()
        for index in indices {
            let (collection, rkey, cid) = Self.records[index]
            repo.add(collection: collection, rkey: rkey, cid: cid)
        }
        return repo
    }

    @Test func empty() {
        let empty = LtHash()
        #expect(empty.isEmpty)
        #expect(empty.digest.hexString == "e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad")
        #expect(empty.digest == Data(SHA256.hash(data: Data(count: 2048))))
    }

    @Test func referenceDigests() {
        #expect(
            repo(adding: [0]).setHash.digest.hexString
                == "d691bb18c84570f3532c76a34fe8ffc40e6999dbc05acfbc6ece5cc8d90eb6af")
        let three = "701f1a5dd20dce23e7a97e0e7e5ce8171267a95a96414bd47528426f5082e828"
        #expect(repo(adding: [0, 1, 2]).setHash.digest.hexString == three)
        // Order doesn't matter.
        #expect(repo(adding: [2, 1, 0]).setHash.digest.hexString == three)
    }

    @Test func addThenRemove() {
        var repo = repo(adding: [0, 1, 2])
        let (collection, rkey, cid) = Self.records[1]
        repo.remove(collection: collection, rkey: rkey, cid: cid)
        #expect(repo.setHash.digest.hexString == "22e7259cb25bc8bcbf557f5a6757a8b2393ae8e34f60a43cc9855a96e2ab4811")
        #expect(repo == self.repo(adding: [0, 2]))
        for (collection, rkey, cid) in [Self.records[0], Self.records[2]] {
            repo.remove(collection: collection, rkey: rkey, cid: cid)
        }
        #expect(repo.setHash.isEmpty)
    }

    /// Lanes wrap mod 2^16 in both directions, as the reference's `Uint16Array` does.
    @Test func removingFromEmptyWraps() {
        let (collection, rkey, cid) = Self.records[0]
        var repo = RepoSetHash()
        repo.remove(collection: collection, rkey: rkey, cid: cid)
        #expect(repo.setHash.digest.hexString == "bc44699862b37a3628eb1239fcce7db7c636f33d623b74d332d5ae0de14eb69e")
        repo.add(collection: collection, rkey: rkey, cid: cid)
        #expect(repo.setHash.isEmpty)
    }

    /// A create, a create, an update and a delete, as `listRepoOps` reports them.
    @Test func ops() {
        let (collection, first, firstCID) = Self.records[0]
        let (_, second, secondCID) = Self.records[1]
        var repo = RepoSetHash()
        repo.applyOp(collection: collection, rkey: first, prev: nil, cid: firstCID)
        repo.applyOp(collection: collection, rkey: second, prev: nil, cid: secondCID)
        repo.applyOp(collection: collection, rkey: first, prev: firstCID, cid: Self.edited)
        repo.applyOp(collection: collection, rkey: second, prev: secondCID, cid: nil)

        let expected = Data(hex: "3c38b064fad6b68bbf67a985b5f94982dbe617f8757a737b4c6e7b85e75d165c")
        #expect(repo.matches(commitData: expected))
        #expect(!self.repo(adding: [0]).matches(commitData: expected))
        var direct = RepoSetHash()
        direct.add(collection: collection, rkey: first, cid: Self.edited)
        #expect(direct == repo)
    }

    @Test func elements() {
        #expect(
            RepoSetHash.element(collection: "a.b.c", rkey: "self", cid: "bafyrei")
                == "a.b.c/self/bafyrei")
    }

    /// The state is the BLAKE3 expansion's lanes, little-endian, and survives a round trip.
    @Test func state() {
        var hash = LtHash()
        hash.add("hello world")
        let state = hash.state
        #expect(state.count == 2048)
        #expect(state == Data(BLAKE3.hash("hello world".utf8, byteCount: 2048)))
        let lanes = (0..<4).map { UInt16(state[2 * $0]) | UInt16(state[2 * $0 + 1]) << 8 }
        #expect(lanes == [18903, 61313, 2727, 34828])
        #expect(hash.digest.hexString == "468ad463b6426dc2619738f91cd783f83f113252082017c2166694968366f7f0")

        let restored = LtHash(state: state)
        #expect(restored == hash)
        #expect(restored?.digest == hash.digest)
        #expect(LtHash(state: Data(count: 2047)) == nil)
        #expect(LtHash(state: Data(count: 2048)) == LtHash())
    }
}

extension Data {
    fileprivate init(hex: String) {
        let digits = Array(hex.utf8)
        self.init(
            stride(from: 0, to: digits.count, by: 2).map {
                UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
            })
    }
}

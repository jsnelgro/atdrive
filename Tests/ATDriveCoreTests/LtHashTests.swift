import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// Expected digests come from running the reference algorithm (`lthash.ts`, `repo-commit.ts` and
/// `util.ts` in `packages/space` on permissioned-data-alpha) in Node with @noble/hashes 1.6.1.
@Suite struct LtHashTests {
    static let node = "me.jsnelgro.atdrive.node"
    static let version = "me.jsnelgro.atdrive.version"
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
                == "5f0c3db4ce1e5513c662bb9e8c9a7e2ebf847bf04fce5b75d0a56cf12147b858")
        let three = "5daf9d6d0d308f21a04556ab86d0642d4cebb17e578273b36eff90c7880b7097"
        #expect(repo(adding: [0, 1, 2]).setHash.digest.hexString == three)
        // Order doesn't matter.
        #expect(repo(adding: [2, 1, 0]).setHash.digest.hexString == three)
    }

    @Test func addThenRemove() {
        var repo = repo(adding: [0, 1, 2])
        let (collection, rkey, cid) = Self.records[1]
        repo.remove(collection: collection, rkey: rkey, cid: cid)
        #expect(repo.setHash.digest.hexString == "ebf34b663f3667f86c94a8a83afb1001f35a70b4bc67b1584edc58963a476a5b")
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
        #expect(repo.setHash.digest.hexString == "c28269b8a906dac7ffa15abb105494b0f9336e235e0111fbebc90ccc2235bfe8")
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

        let expected = Data(hex: "b57262fe323d87e492b7378a61e9d6816a960f9f53af4580e33b1cd68eacb6da")
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

# Prints the known answers in Tests/ATDriveCoreTests/LtHashTests.swift, computed without any
# ATDrive code: python3 Tests/vectors/lthash_vectors.py (needs the `blake3` package).
# Each element `<collection>/<rkey>/<cid>` expands with BLAKE3 to 1024 little-endian 16-bit lanes,
# added to (or subtracted from) the state mod 2^16; the digest is SHA-256 of the state.
import hashlib, struct
from blake3 import blake3

node, version = "app.atdrive.node", "app.atdrive.version"
records = [
    (node, "3m5xkq2v7ra2c", "bafyreib5xi33wcdr5xx3sw3gkuji3pqzejjc6f56btiqrhxx3vc4tow42e"),
    (node, "3m5xkq2wdcs2c", "bafyreicv6ocy5g7tbbs2a2meuypkjz6a6b4fjhgrcbvbcka2wop7rtlyae"),
    (version, "3m5xkq2wdcs2d", "bafyreidtelq4he57fx75pqqekctliinynajyq2lll6xojzosdtzngwhlla"),
]
edited = "bafyreihe7fzvofj5dhrno6floqztkgxgl3rujlvr33hwjrj7b67jh32w64"


class SetHash:
    def __init__(self): self.lanes = [0] * 1024
    def combine(self, collection, rkey, cid, sign):
        expanded = struct.unpack("<1024H", blake3(f"{collection}/{rkey}/{cid}".encode()).digest(length=2048))
        self.lanes = [(a + sign * b) % 65536 for a, b in zip(self.lanes, expanded)]
    def add(self, *record): self.combine(*record, 1)
    def remove(self, *record): self.combine(*record, -1)
    def digest(self): return hashlib.sha256(struct.pack("<1024H", *self.lanes)).hexdigest()


def repo(indices):
    hash = SetHash()
    for index in indices: hash.add(*records[index])
    return hash

print("referenceDigests one", repo([0]).digest())
print("referenceDigests three", repo([0, 1, 2]).digest())
hash = repo([0, 1, 2]); hash.remove(*records[1]); print("addThenRemove", hash.digest())
hash = SetHash(); hash.remove(*records[0]); print("removingFromEmptyWraps", hash.digest())
hash = SetHash(); hash.add(node, records[0][1], edited); print("ops", hash.digest())

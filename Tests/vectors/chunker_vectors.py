# Prints the fixed vectors in Tests/ATDriveCoreTests/ChunkerTests.swift, computed without any
# ATDrive code: python3 Tests/vectors/chunker_vectors.py [gear table label] (needs the
# `cryptography` package). A plain, non-streaming FastCDC with normalized chunking at level 2.
import hashlib, struct, sys
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

LABEL = (sys.argv[1] if len(sys.argv) > 1 else "app.atdrive chunker gear table").encode()
M64 = (1 << 64) - 1


def random_data(count, seed):
    """SplitMix64, 8 little-endian bytes per step."""
    out, state = bytearray(), seed
    while len(out) < count:
        state = (state + 0x9E3779B97F4A7C15) & M64
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        out += struct.pack("<Q", z ^ (z >> 31))
    return bytes(out[:count])


def gear(seed):
    table = HKDF(hashes.SHA256(), 256 * 8, None, LABEL).derive(seed or bytes(32))
    return struct.unpack("<256Q", table)


def ends(data, min_size, avg, max_size, seed=None):
    g = gear(seed)
    bits = avg.bit_length() - 1
    small = (M64 << (64 - min(bits + 2, 64))) & M64
    large = (M64 << (64 - max(bits - 2, 1))) & M64
    result, start = [], 0
    while start < len(data):
        n = min(len(data) - start, max_size)
        cut = n
        if n > min_size:
            h, i = 0, min_size
            while i < n:
                h = ((h << 1) + g[data[start + i]]) & M64
                if h & (small if i < avg else large) == 0:
                    cut = i  # the chunk ends before the byte that matched
                    break
                i += 1
        start += cut
        result.append(start)
    return result


seed = bytes(range(32))
small = (4 << 10, 16 << 10, 64 << 10)
standard = (256 << 10, 1 << 20, 4 << 20)
data = random_data(1 << 20, 1)
print("generator", hashlib.sha256(data).hexdigest())
print("small", ends(data, *small))
print("small seeded", ends(data, *small, seed))
data = random_data(12 << 20, 2)
print("standard data", hashlib.sha256(data).hexdigest())
print("standard", ends(data, *standard))
print("standard seeded", ends(data, *standard, seed))

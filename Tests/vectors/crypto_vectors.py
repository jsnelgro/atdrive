# Prints the known answers in Tests/ATDriveCoreTests/CryptoVectorTests.swift, computed without
# any ATDrive code: python3 Tests/vectors/crypto_vectors.py (needs the `cryptography` package).
import base64, hashlib, hmac, struct
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF, HKDFExpand
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

def b(r): return bytes(r)
def b64(x): return base64.b64encode(x).decode().rstrip('=')
def hkdf(ikm, info, n=32): return HKDF(hashes.SHA256(), n, None, info).derive(ikm)
space = "at://did:plc:test/space/app.atdrive.drive/default"
key = b(range(0,32)); second = b(range(100,132)); recovery = b(range(32,64))

# sealing
aad = b"".join(p.encode()+b"\0" for p in ["atdrive record v2", space, "app.atdrive.node", "3jzfcijpj2z2a"])
nonce = b(range(0xa0,0xac))
ct = AESGCM(hkdf(key, b"atdrive record sealing v1")).encrypt(nonce, b'{"name":"notes.txt","size":42}', aad)
print("sealing", b64(nonce+ct))

# recovery wrap
info = b"atdrive keyring v2\0" + space.encode() + b"\0"
nonce = b(range(0xb0,0xbc))
ct = AESGCM(hkdf(recovery, b"atdrive recovery wrap v1")).encrypt(nonce, key+second, info)
print("recovery", b64(nonce+ct))

# HPKE (RFC 9180), DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM
KEM_ID, KDF_ID, AEAD_ID = 0x0020, 0x0001, 0x0002
def extract(salt, ikm): return hmac.new(salt if salt else b"\0"*32, ikm, hashlib.sha256).digest()
def expand(prk, info, n): return HKDFExpand(hashes.SHA256(), n, info).derive(prk)
def labeled_extract(suite, salt, label, ikm): return extract(salt, b"HPKE-v1"+suite+label+ikm)
def labeled_expand(suite, prk, label, info, n): return expand(prk, struct.pack(">H", n)+b"HPKE-v1"+suite+label+info, n)
kem_suite = b"KEM"+struct.pack(">H", KEM_ID)
hpke_suite = b"HPKE"+struct.pack(">HHH", KEM_ID, KDF_ID, AEAD_ID)
def pub(sk): return sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
def extract_and_expand(dh, kem_context):
    return labeled_expand(kem_suite, labeled_extract(kem_suite, b"", b"eae_prk", dh), b"shared_secret", kem_context, 32)
def key_schedule(mode, shared, info):
    ctx = bytes([mode]) + labeled_extract(hpke_suite, b"", b"psk_id_hash", b"") + labeled_extract(hpke_suite, b"", b"info_hash", info)
    secret = labeled_extract(hpke_suite, shared, b"secret", b"")
    return labeled_expand(hpke_suite, secret, b"key", ctx, 32), labeled_expand(hpke_suite, secret, b"base_nonce", ctx, 12)
def seal_base(skE, pkR, info, pt):
    enc = pub(skE); dh = skE.exchange(pkR)
    k, n = key_schedule(0, extract_and_expand(dh, enc+pkR.public_bytes(Encoding.Raw, PublicFormat.Raw)), info)
    return enc, AESGCM(k).encrypt(n, pt, b"")
def seal_auth(skE, pkR, skS, info, pt):
    enc = pub(skE); pkRm = pkR.public_bytes(Encoding.Raw, PublicFormat.Raw)
    dh = skE.exchange(pkR) + skS.exchange(pkR)
    k, n = key_schedule(2, extract_and_expand(dh, enc+pkRm+pub(skS)), info)
    return enc, AESGCM(k).encrypt(n, pt, b"")


device = X25519PrivateKey.from_private_bytes(b(range(64,96)))
sender = X25519PrivateKey.from_private_bytes(b(range(128,160)))
eph = X25519PrivateKey.from_private_bytes(b(range(160,192)))
enc, ct = seal_auth(eph, device.public_key(), sender, info, key+second)
print("sender", b64(pub(sender))); print("enc", b64(enc)); print("ct", b64(ct))

dh = device.exchange(X25519PublicKey.from_public_bytes(enc)) + device.exchange(sender.public_key())
k, n = key_schedule(2, extract_and_expand(dh, enc+pub(device)+pub(sender)), info)
assert AESGCM(k).decrypt(n, ct, b"") == key+second

# ATDrive storage format

What an ATDrive client reads and writes, precisely enough to write another client (a web app,
say). The Swift implementation is `Sources/ATDriveCore`; `lexicons/` has the record schemas;
`Tests/ATDriveCoreTests/CryptoVectorTests.swift` has known answers for everything under
*Cryptography*, and `Tests/vectors/crypto_vectors.py` computes them without any ATDrive code.

Alpha: nothing here is stable yet, and nothing is backward compatible.

## A drive

- A drive is one atproto space: `at://<did>/space/app.atdrive.drive/<key>`. The home
  drive's key is `default`. Everything below is per space: a shared folder will be another space
  of the same type, with its own settings, mode, keys, history and change feed.
- **A space's address** is always written in that form, `at://<did>/space/<type>/<key>` (the
  spaces alpha's first one), wherever this document puts one: in records (`mount`, `invite`,
  `declined`), in links, and in the associated data and key-wrapping info below. The PDS has
  addressed spaces as `at:space/<did>/<type>/<key>` since Nov 2026, and takes only that form in
  space parameters: a client sends it there, and reads either form as the same space.
- Collections: `node` (one record per file or folder), `version` (one per change),
  `chunks` (the rest of chunk lists too long for one record), `settings` (one record, key
  `self`), `device` (encrypted drives: one per device, plus `recovery`). All under
  `app.atdrive.`.
- File contents are blobs, referenced from `chunks` arrays in records. A blob lives while a
  record references it.

## Plain and sealed records

Every `node`, `version`, `chunks` and `settings` record is stored in one of two forms, and says
which by whether it has a `sealed` field.

- **Plain:** the record's fields as JSON, as in the lexicon.
- **Sealed:** `{"$type", "chunks"?, "sealed": {"keyID", "sealed"}}`. `chunks` (blob refs) stays
  readable so the PDS keeps the blobs. Every other field is in a JSON object encrypted in
  `sealed` (see *Sealing*).

**The drive's mode is the form of its settings record:** sealed means the drive is encrypted,
plain means it isn't. A client writes every record in the drive's mode, and re-reads the settings
whenever that record's CID changes.

Reading, a client accepts:

| Record | Plain drive | Encrypted drive |
|---|---|---|
| Plain | yes | only while `settings.converting` |
| Sealed with a key in the drive's keyring | (there's no keyring) | yes |
| Sealed with a key in `settings.retiredKeys` | yes | only while `settings.converting` |
| Sealed with any other key | unreadable | unreadable |

On an encrypted drive, a plain record or one sealed with a retired key could have been written
by the PDS, which is why it's refused once the drive has finished converting. A record a client
can't read is **never treated as deleted**: it's left alone, on the drive and locally.

## Records

`node` (key: a TID, the file or folder's permanent ID):
`name`, `parent?` (a node key), `kind` (`file`, `folder` or `mount`), `createdAt`, `version?` (key
of its current version), for files `size`, `sha256` (hex, of the whole file), `modifiedAt?`,
`chunks`, `chunkIDs?`, `chunkKey?`, `contentsFrom?`, `continuations?`, `continuationsFrom?`, and
for mounts `mount` (see *Sharing*).

`version` (key: a TID made when the change was): `node`, `change` (`created`, `edited`, `moved`,
`deleted`, `restored`, `shared`), `device` (a name), `prev?` (the version the change was based
on), and the node's state after the change (none after a delete, or `shared`): `name`, `parent`,
`kind`, `size`, `sha256`, `createdAt`, `modifiedAt`, `mount`, and either the chunk list (`chunks`,
`chunkIDs?`, `chunkKey?`, `continuations?`, `continuationsFrom?`) or `contentsFrom`, the version
that holds it.

- Every change to a node writes its `version` in the same `applyWrites`. Two versions with the
  same `prev` are a race; the loser is settled by `ConflictRules`.
- A node's `chunks` are a copy of the list held by the version `contentsFrom` names.

Chunk lists:
- `chunks`: blob refs, in order. The file is the chunks' contents concatenated.
- `chunkIDs`: present if the chunks are encrypted: one ID per blob, in the same order (32 bytes,
  base64 without padding). `chunkKey`: the key ID of the drive key the IDs were made with (the
  keyring's first key at the time). A list is all encrypted or all plain.
- A list too long for a record (about 400 kB of JSON) is in `chunks` records instead, keyed
  `<version key>-<n>` for `n` from `continuationsFrom` (default 1), `continuations` of them; the
  node and version then hold no `chunks`. Rewriting a list writes new parts numbered after the
  old ones, then switches the version and node to them in one write, then deletes the old parts.

`settings` (key `self`): `retentionDays` (default 30), `driveID` (random; a different one means
the drive was wiped and created again), `generation` (incremented on every change), `converting`
(encrypted drives), `retiredKeys` (raw drive keys, published when encryption was turned off),
`sharingKey?` (home drives: the account's raw X25519 sharing key), `name?` (shares: the shared
file's or folder's name), `file?` (shares: `true` when it's one file, which the space holds at
its top; the share is shown as that file rather than a folder).

`device` (encrypted drives; key: the device's ID, a TID): `name`, `publicKey` (raw X25519),
`keyring?` (the keyring wrapped for it), `member?` (sealed `{id, name, publicKey}`),
`approvedBy?`, `createdAt`. Key `recovery`: `recoveryKeyring`.

## Chunking

FastCDC with a gear table derived from a 32-byte seed (`Chunker.swift`; `ChunkerTests` has fixed
vectors, and `Tests/vectors/chunker_vectors.py` computes them). Minimum 256 KiB, average 1 MiB,
maximum 4 MiB. The gear table is HKDF-SHA256 of the seed (no salt, info
`app.atdrive chunker gear table`), 2048 bytes read as 256 little-endian `UInt64`s.

- Plain drive: the seed is 32 zero bytes, so every client cuts the same way.
- Encrypted drive: the seed is the first drive key's `atdrive chunker seed v1` subkey.

Any cut is valid for reading. Cutting the same way only matters for skipping chunks the drive
already has, and for reusing chunks of a local copy.

## Cryptography

Only on encrypted drives. Every primitive is in WebCrypto: AES-256-GCM, HKDF-SHA256,
HMAC-SHA256, SHA-256, X25519.

**Drive keys.** 32 random bytes each. The keyring is every key so far, oldest first; the newest
seals records, and the first names chunks. Subkeys are `HKDF-SHA256(ikm = key, salt = none,
info = <label>, 32 bytes)`:

| Label | Use |
|---|---|
| `atdrive key id v1` | 8 bytes, as hex: the key ID |
| `atdrive record sealing v1` | AES-256-GCM key for sealed records |
| `atdrive chunk id v1` | HMAC key that names chunks |
| `atdrive chunker seed v1` | chunker seed |
| `atdrive key fingerprint v1` | as hex: what a device remembers of a key it accepted |

**Sealing.** `sealed.sealed` is a random 12-byte nonce, the ciphertext, then the 16-byte tag:
AES-256-GCM under the record-sealing subkey of the key `sealed.keyID` names, over the payload as
JSON. Associated data: `atdrive record v2`, the space's URI, the collection NSID and the record
key, each followed by a zero byte. A record that fails to open is unreadable (tampered with, or
moved from another record or drive).

**Chunks.** ID = `HMAC-SHA256(chunk-id subkey of the first key, plaintext)`. Chunk key =
`HKDF-SHA256(ikm = ID, info = "atdrive chunk key v1")`. The blob is AES-256-GCM of the plaintext
under the chunk key with a nonce of 12 zero bytes, ciphertext then tag (each key encrypts exactly
one plaintext). Identical chunks give identical blobs, so they're stored once. An ID is all it
takes to decrypt its chunk, so IDs are only ever in sealed records, or in plain ones after
encryption was turned off.

**Device keys and the keyring.** Each device has an X25519 key pair. `device.keyring` is the
keyring (keys concatenated, oldest first) wrapped with HPKE (RFC 9180) in auth mode:
DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM; `info` = `atdrive keyring v2`, a zero byte,
the space's URI, a zero byte; `sender` is the wrapping device's public key. `recoveryKeyring` is
the same plaintext under AES-256-GCM (random nonce, then ciphertext and tag) with the key
`HKDF-SHA256(recovery key, info = "atdrive recovery wrap v1")` and the HPKE `info` as associated
data.

**The roster** is the device records whose `member` opens with the keyring's *current* key
(associated data as for any sealed record, in the `device` collection) and names that record's
key and `publicKey`. Removing a device rotates the key and re-seals every remaining `member`, so
an old `member` restored by the PDS is void.

**Which keyring a device accepts** (`KeyTrust`): one that holds every key it accepted before, and
that was wrapped by itself, or (its first) by the device whose pairing code the user compared,
or (later) by a device in the roster. The pairing code is the first 8 bytes of
`SHA-256("atdrive pairing code v2" || both public keys, sorted)`, as a number modulo 10^16.

**The recovery key** is 32 random bytes, written as 56 Crockford base32 characters: the key, then
the first 3 bytes of `SHA-256("atdrive recovery key checksum v1" || key)`.

## Switching modes

- **Off → on:** one `applyWrites`: the settings sealed with a new keyring (`converting: true`,
  `generation + 1`, `retiredKeys` kept), the `recovery` record, the device's own record. Then
  every record that isn't sealed with the new keyring is rewritten, and every chunk list that
  isn't encrypted under its first key is downloaded and stored again. When none is left,
  `converting` is cleared.
- **On → off:** one `applyWrites`: the settings plain, with the keyring's keys appended to
  `retiredKeys` (`generation + 1`), and every `device` record deleted. Nothing else has to be
  rewritten: what's sealed opens with the retired keys. Rewriting it as plain is optional.
- **A device that held the keys** accepts plain settings only if `retiredKeys` holds every key it
  accepted before (compare fingerprints). The PDS can make settings plain, but can't publish
  keys it never had. It also refuses sealed settings whose `generation` is lower than one it has
  read.

## Sharing

A share is a drive of its own: a space of the same type (`app.atdrive.drive`), its key
26 base32 characters (128 random bits), under the `memberspace` policy, with the records above.
Its owner's drive mounts it where the folder was.

- **`mount`** (in a `node` of kind `mount`): `space` (its `at://` address), `keyring?` (raw keys,
  oldest first: an encrypted space the drive's owner shared; only ever in a sealed record),
  `linkKey?` (32 bytes: an encrypted share opened from its link, or the owner's while its link is
  on). Its children are the mounted space's top-level nodes. Node IDs across spaces are
  `<mount key>/<rkey>`.
- **`app.atdrive.shareKey`** (public repo, key `self`): `publicKey` (raw X25519),
  `protected` (whether the private key is kept sealed), `createdAt`.
- **`member`** (in an encrypted share; key: the member's DID): `keyring` (the share's keyring
  wrapped as a device's is, HPKE auth mode, X25519 / HKDF-SHA256 / AES-256-GCM, `info` the
  keyring info for the share's space, from the owner's sharing key to the member's), `membership`
  (sealed `{did, publicKey}`, for this record), `createdAt`. A member accepts it only if `sender`
  is the owner's published sharing key, and `membership` opens and names them.
- **`link`** (in an encrypted share with its link on; key `self`): `keyring`, bytes: AES-256-GCM
  (12-byte nonce, ciphertext, 16-byte tag) of the raw keys, under
  `HKDF-SHA256(ikm: link key, info: "atdrive link key v1", 32 bytes)`, with the keyring info as
  associated data.
- **`contact`** (home drive; key: a DID): `publicKey`, `verifiedAt`: a sharing key verified with a
  code. Sealed on an encrypted drive.
- **Inbox** (`at://<did>/space/app.atdrive.inbox/self`): each account's, under `memberspace` with
  no members, `publicRead: false` and `publicWrite: true`, so only its owner reads it and anyone's
  writes to it are tracked (`listWriters`).
- **`app.atdrive.invite`** (the sharer's repo in the recipient's inbox; key: the share's space
  key): `space` (the share's address), `createdAt`. Written when someone is added to a share,
  deleted when they're taken off or it stops being shared. A recipient counts only invites whose
  space's authority is the invite's writer, of type `app.atdrive.drive`, and opens the share (as a
  member) for its name: an invite carries nothing else, so an encrypted share's name stays sealed.
- **`declined`** (home drive; key: the first 16 bytes of SHA-256 of the share's address, hex):
  `space`, `declinedAt`: an invite said no to. Sealed on an encrypted drive.
- **Links:** `atdrive://open?at=<the address, percent-encoded>`, plus `#<link key, base64url>` for
  an encrypted share's public link.
- **Verification code:** as the pairing code, with the label `atdrive sharing key verification v1`
  and both sharing keys.
- **Reading a share** follows the spaces protocol (0016): a delegation token from your PDS (none
  for a public share), `authorizeSpaceSync` at the owner's PDS with a fresh P-256 `did:key`, reads
  signed per RFC 9421 over `authorization` and `atproto-space-audience`, and commits checked with
  their MAC (HPKE export-only secret from the owner's `#atproto_kem` key, HMAC-SHA256).

## A web client

Nothing in the format needs a native client.

- **Plain drive:** no cryptography at all. List records, read fields, fetch blobs, verify
  `sha256`. Writing needs FastCDC (or any chunking: files then just don't share chunks with ones
  other clients wrote) and SHA-256.
- **Encrypted drive:** the browser is a device: an X25519 key pair (WebCrypto can keep the
  private key non-extractable), approved from another device or with the recovery key. HPKE is a
  few HKDF and X25519 calls on top of WebCrypto.
- **The exact-listing check** (`RepoState.check`: an LtHash over BLAKE3) is an optimization that
  needs BLAKE3; a client without it lists the drive instead of following the change feed.
- A hosted page can't be trusted with an encrypted drive's keys any more than its host: that's
  a product decision for the web milestone, not a format one.

# Security review: Storage v2

A review of authentication, key handling, the storage format and what's kept on disk, done on
the Storage v2 branch (PR #7) after encryption became optional. It covers `Sources/ATDriveCore`
and the CLI. The Mac app's code was read but not run. Nothing here has been checked against the
live alpha PDS.

This is one reviewer reading the code that same reviewer had just reworked. It's a careful pass
with a list of what was looked at, not an independent audit: get one before trusting an
encrypted drive with anything that matters.

## What's being protected, and from whom

| Who | Plain drive (the default) | Encrypted drive |
|---|---|---|
| Other atproto accounts, the public | Kept out by the space's policy (the PDS enforces it) | Same |
| Whoever runs the PDS, or breaks into it | **Can read and change everything.** That's the deal | Can't read file contents, names, folders, sizes of small parts, or history. Can't forge or alter a record without it showing. **Can** delete, withhold, or serve an older copy; sees record counts, chunk sizes, timing, which chunks are shared, and device names |
| Someone with a device's files (`session.json`, `device.json`) | Has the account's session until it's revoked | Also has that device's key, so the drive, until the device is removed |
| A removed device | n/a | Keeps what it could read. Can't read what's written afterwards. Can still write until its session is revoked (#14) |

A plain drive is as private as a Dropbox or Google Drive account: private to you, readable by
the operator. Everything below about keys applies only to encrypted drives.

## Findings fixed on this branch

1. **A record sealed for one drive opened in another with the same key.** Sealing's associated
   data was the collection and record key only. Harmless with one space per account; with shared
   folders as spaces, a record could be replayed across them. Sealing and key wrapping now bind
   the space's URI. (`Sealing.associatedData`, `KeyWrapping.info`)
2. **The roster could lose an approval or undo a removal** (#13): it was one list in the
   settings record, and spaces have no compare-and-swap. Each device's membership is now sealed
   in its own record, with the drive's current key, so approvals don't collide, and a removed
   device's old record can't be restored by the PDS. (`Drive.roster`)
3. **The PDS could turn encryption off.** New with optional encryption: the settings record
   says whether the drive is encrypted, and the PDS can rewrite it. A device that has held the
   keys now believes "not encrypted" only if the settings publish those keys, which only the
   drive's devices can do; otherwise it refuses to write and says why. (`Drive.open`,
   `DriveAccessError.encryptionRemoved`)
4. **Plain records on an encrypted drive.** Needed while a drive is being encrypted, but a way
   for the PDS to inject records afterwards. They're read only while the sealed settings say
   `converting`; after that they're held as unreadable, and only an explicit `atdrive encryption
   on` adopts them. (`Drive.unseal`)
5. **Replaying the `converting` settings** would reopen that window. Settings carry a
   generation, and a device refuses sealed settings older than ones it has read.
   (`DeviceTrust.settingsGeneration`)
6. **A keyring that doesn't open the drive's settings was accepted** if its sender was trusted.
   It's now refused: it isn't this drive's keyring (any more).
7. **`.atdrive/` in a synced folder was world-readable** by default (it holds the drive's
   metadata, and partial downloads). The folder is now 0700 and its files 0600. What's in
   `drive.json` is still decrypted (#15).
8. **Sync could mistake "can't read the drive any more" for "the drive is gone"** once another
   device turned encryption on. It now stops with the real reason, before the drive-identity
   check, and never deletes local files over it.
9. **A snapshot read before a change of mode or keys was patched, not re-read,** so a record
   could stay readable after the drive stopped accepting its form. The drive is listed again
   whenever how it reads records changes.
10. **HPKE used ChaCha20-Poly1305,** which WebCrypto lacks: a browser client would have had to
    ship its own cipher. Now AES-256-GCM. Not a weakness, but one less place for a web client to
    get crypto wrong.

## Open findings

Ordered by how much they matter. None is new on this branch unless it says so.

**High**

- **A removed device can still write, and delete** (#14). Removal rotates the key, but the
  device keeps an account session. It can delete every record, or write records sealed with old
  keys, which other devices still read. Fix: revoke its OAuth session as part of `devices
  remove` if the PDS offers that, and have devices that have seen a rotation refuse records
  sealed with an older key that are newer than the rotation.
- **Secrets are plain files** (`session.json`, `device.json`, mode 600; on the Mac, in the App
  Group container). Anything running as the user can read the OAuth tokens and the device key.
  Fix: the Keychain on Apple platforms (shared access group for the extension); on Linux,
  the Secret Service where there is one.

**Medium**

- **A device that never held the keys can't tell an encrypted drive from a plain one** (new).
  The PDS decides what a new device sees first: shown plain settings, it will use the drive
  unencrypted, and what it writes is readable. Other devices then ignore those records, which
  is how it shows. `atdrive login` says which kind of drive it opened; nothing more can be done
  without a secret the new device already shares with the drive. Related: a device that was
  offline while encryption was turned off and on again can be shown the old, genuine "off"
  settings.
- **The OAuth scope is `space:*`**: every space the account has, not just ATDrive's. It's that
  way until the lexicons are published (PLAN.md, *Protocol notes*). Narrow it then.
- **`.atdrive/drive.json` holds decrypted metadata** for an encrypted drive, including chunk
  IDs, which decrypt chunks (#15). Now owner-only, but still in backups of the folder.
- **Converting writes each file to the system's temporary folder** in the clear (mode 600,
  deleted afterwards; left behind by a crash). Use a private folder beside the session.
- **Rollback.** The PDS can serve an older copy of the whole drive, or of single records. The
  settings' generation covers only the settings, and only on devices that have seen newer ones.
  A drive-wide fix needs a signed head that every write advances, which spaces can't do without
  compare-and-swap.
- **Two devices turning encryption on at the same moment** each make a keyring; the last
  settings write wins, and what the other device sealed meanwhile is unreadable to everyone
  else (it's held, not lost, while that device still runs). Rare; a re-read after the write
  would catch it.

**Low**

- **The `iss` check at sign-in is skipped when the response has no `iss`.** atproto servers
  must send it; require it.
- **Settings sealed when encryption is turned on come from the plain record,** which the PDS
  could have changed (a short retention, say) beforehand. Show them when turning it on.
- **Times come from device clocks** (TIDs), and decide which side of a race lost and what
  pruning keeps. A device with a wrong clock, or a removed one, can skew both.
- **Device names are readable** on an encrypted drive.
- **Pairing codes are 16 digits compared by eye.** Sound (see `PairingCode`), but people skip
  comparing. The recovery key path avoids it.
- **Turning encryption off publishes every key the drive has had.** That's the design. When
  shared folders exist, a drive that holds the keyrings of encrypted shares (in mount records)
  would expose those too: turning encryption off has to handle that first (PLAN.md).

## What was checked

- **Key derivation and use:** each use has its own HKDF label; AES-GCM nonces are random per
  record (96 bits; fine for the number of records a drive writes under one key) and fixed only
  where each key encrypts one plaintext (chunks); no key is used raw.
- **Known answers:** sealing, chunks, both keyring wraps, the pairing code and the recovery key
  text are pinned by `CryptoVectorTests`, computed with Python's `cryptography` and an
  independent HPKE (`Tests/vectors/crypto_vectors.py`). The format change went through that.
- **Every way a stored record becomes a value** goes through `Drive.unseal`
  (`StoredRecords.swift`): which keys open it, and when an unsealed one is accepted.
- **Which keyrings a device takes** (`KeyTrust`), and every caller of `accept`.
- **Tampering tests** (`EncryptionTests`, `DeviceTests`, `SwitchingTests`): changed, moved,
  replayed and forged records, device records, settings and keyrings; what the PDS stores on
  each kind of drive; that nothing unreadable is ever taken for deleted.
- **Sign-in:** PKCE (S256), `state`, the issuer, that the token's `sub` is the account asked for,
  DPoP-bound tokens, the redirect listener on 127.0.0.1 only.
- **Files written:** permissions of the session, device identity and sync state; that keys,
  chunk IDs and recovery keys don't appear in logs or descriptions.

Not checked: the Mac app and extension at run time, anything against a real PDS, side channels,
and the PDS's own enforcement of space policies.

# Security review: Storage v2

A review of authentication, key handling, the storage format and what's kept on disk, done on
the Storage v2 branch (PR #7) after encryption became optional. It covers `Sources/ATDriveCore`
and the CLI. The Mac app's code was read but not run. Nothing here has been checked against the
live alpha PDS.

This is one reviewer reading the code that same reviewer had just reworked. It's a careful pass
with a list of what was looked at, not an independent audit: get one before trusting an
encrypted drive with anything that matters (#41).

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
- **Secrets are plain files** (#32: `session.json`, `device.json`, mode 600; on the Mac, in the App
  Group container). Anything running as the user can read the OAuth tokens and the device key.
  Fix: the Keychain on Apple platforms (shared access group for the extension); on Linux,
  the Secret Service where there is one.

**Medium**

- **A device that never held the keys can't tell an encrypted drive from a plain one** (#35, new).
  The PDS decides what a new device sees first: shown plain settings, it will use the drive
  unencrypted, and what it writes is readable. Other devices then ignore those records, which
  is how it shows. `atdrive login` says which kind of drive it opened; nothing more can be done
  without a secret the new device already shares with the drive. Related: a device that was
  offline while encryption was turned off and on again can be shown the old, genuine "off"
  settings.
- **The OAuth scope is `space:*`** (#33): every space the account has, not just ATDrive's. It's that
  way until the lexicons are published (PLAN.md, *Protocol notes*). Narrow it then.
- **`.atdrive/drive.json` holds decrypted metadata** for an encrypted drive, including chunk
  IDs, which decrypt chunks (#15). Now owner-only, but still in backups of the folder.
- **Converting writes each file to the system's temporary folder** in the clear (#15; mode 600,
  deleted afterwards; left behind by a crash). Use a private folder beside the session.
- **Rollback** (#36). The PDS can serve an older copy of the whole drive, or of single records. The
  settings' generation covers only the settings, and only on devices that have seen newer ones.
  A drive-wide fix needs a signed head that every write advances, which spaces can't do without
  compare-and-swap.
- **Two devices changing the keys at the same moment** (#37). Turning encryption on: each makes
  a keyring; the last settings write wins, and what the other device sealed meanwhile is
  unreadable to everyone else (it's held, not lost, while that device still runs). Removing
  devices: two rotations can leave a device refusing its keyring, until the recovery key gets
  it out. Rare; a re-read after the write would catch both.

**Low**

- **The `iss` check at sign-in is skipped when the response has no `iss`** (#34). atproto servers
  must send it; require it.
- **Settings sealed when encryption is turned on come from the plain record** (#38), which the PDS
  could have changed (a short retention, say) beforehand. Show them when turning it on.
- **Times come from device clocks** (#40: TIDs), and decide which side of a race lost and what
  pruning keeps. A device with a wrong clock, or a removed one, can skew both.
- **Device names are readable** on an encrypted drive (#39).
- **Pairing codes are 16 digits compared by eye.** Sound (see `PairingCode`), but people skip
  comparing. The recovery key path avoids it.
- **Turning encryption off publishes every key the drive has had.** That's the design. Once
  shared folders exist, that would expose the keyrings of encrypted shares too, so switching a
  drive's encryption either way ends its sharing first (the sharing plan, #27).

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

## Sharing (#42)

Reviewed by the same hands that wrote it, as above: not an independent audit.

| Who | Plain share | Encrypted share |
|---|---|---|
| People it isn't shared with | Kept out by the space's policy: the owner's PDS only issues credentials to members (or anyone, with the link on). The space key is 128 random bits, so a plain share's address can't be guessed | Same, and the content is sealed |
| Whoever runs the owner's PDS | Reads everything, as with a plain drive | Can't read it. Sees the member list, when members read, and the same metadata as for an encrypted drive |
| Whoever runs a member's PDS | Can read it, through the member's own credentials | Can't, unless the member's drive is plain (their sharing key is readable there): the owner is warned when adding them, and `share ls` marks them |
| Someone with the link | Reads it | Reads it: the key is in the link's `#fragment`, which never reaches a server, but anyone the link reaches has it |
| A removed member, or a link turned off | Keeps what they downloaded; the PDS refuses them from then on (credentials are revoked, or expire within minutes) | Same, and what's written afterwards is sealed with a new key they never get |

**What protects an encrypted share's keys**

- A share's keyring is never stored readable: the code refuses to write a mount holding one into
  a plain drive, and switching a drive's encryption moves its shares back into it rather than
  carrying a keyring across.
- Member records are wrapped with HPKE auth mode from the owner's sharing key; a member accepts
  one only if the sender is the key the owner publishes, and its sealed membership opens. The PDS
  can't make one, or bring back a removed member's.
- **The open risk: published sharing keys.** A malicious PDS could publish a key of its own for
  someone, and receive the keyring wrapped for it. Verification codes (`atdrive verify`)
  close it for people who compare codes; for everyone else, ATDrive trusts the first key it sees
  and warns when one changes (a changed key is refused unless the owner confirms). Medium.
- Commits read from someone else's space are MAC-checked with the owner's KEM key, so a host that
  isn't the owner's can't serve a commit that passes. Records themselves carry no MAC in a
  listing: the LtHash check against the commit covers them.

**Fixed after a second review** (a separate reviewer read the branch for key leaks and data loss):

- The PDS could make an encrypted share's settings read plain, and a device would then write to it
  in the clear. A mount now remembers that its space was encrypted (and holding a keyring or link
  key means it was): plain settings there are refused as a downgrade, by owners and link holders.
- Removing a member rotated the key but dropped the link key, so link holders silently stopped
  getting new files. Rotation now keeps it, and rewraps for the link.
- After sharing, turning encryption off failed on old mount versions holding a keyring. History
  on a plain drive now keeps no keyring.
- Deleting your own shared folder left it shared, with no command that listed it. It's now
  unshared first (and stays restorable from the trash).
- Ending a shared file's sharing deleted the mount before copying the file back. Now it copies
  first.
- Adding people after `unshare` failed (the space was `personalspace`). Now it's set back.
- A mount whose own record can't be read made sync delete the share's local copies; a share never
  read showed empty in Finder. Both are held now.
- A member who verified the owner's key now refuses member records from any other key.
- A credential read whose records don't match the MAC'd commit is held, and a MAC failure looks
  the owner's KEM key up again once.

**Open findings**

- **Turning encryption off exposes history** (medium, by design of that switch): it publishes the
  drive's keys, which open its history, including mounts' old versions. Shares of your own are
  deleted when encryption is switched, so their keys there open nothing; but the link key of
  someone else's share you had opened is in that history, and their space may still be public.

- **The scope asks for too much until the lexicons are published** (medium): reading spaces of
  any type from any account (`space:*?authority=*&action=read`), which the consent screen warns
  about. Publishing them and setting `OAuthLogin.lexiconsPublished` narrows it to ATDrive's spaces.
- **A plain drive keeps link keys readable** (low, by design): opening an encrypted share's link
  into a plain drive stores the link key in the mount, where that drive's PDS can read it. The CLI
  says so.
- **A deleted share's copies are deleted on recipients' machines** (by design, as the protocol
  asks): an owner can take back what they shared, including local copies of it.
- **Nothing here has run against the live PDS,** and the Mac's sharing UI hasn't been tried on a
  real Mac.


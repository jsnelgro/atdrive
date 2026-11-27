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
| Whoever runs the PDS, or breaks into it | **Can read and change everything.** That's the deal | Can't read file contents, names, folders, sizes of small parts, or history. Can't forge or alter a record without it showing. **Can** delete, withhold, or serve an older copy; sees record counts, chunk sizes, timing, which chunks are shared, and the name of a device waiting to be approved |
| Someone with a device's secrets (`session.json` and `device.json`, or their Keychain items) | Has the account's session until it's revoked | Also has that device's key, so the drive, until the device is removed |
| A removed device | n/a | Keeps what it downloaded. Once the drive is re-encrypted (`devices rm` does it), its keys open nothing on the PDS, and what it writes with them is refused. Can still delete records until it's signed out on the PDS (#14) |

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

- **A removed device can still delete** (#14). Removal replaces the drive's keys and seals
  everything again with the new one (#46): afterwards the old keys open nothing the PDS serves,
  and a record sealed with one is refused (`formerKey`), so the device can't read or write the
  drive any more. But it keeps an account session, and can delete every record until the user
  signs it out on the PDS's account page; no API lets one client revoke another's OAuth session,
  so `devices rm` prints where to do it. Two narrower gaps: what it writes with the old keys
  while the re-encryption runs is read, and sealed again with the new key; and a device that was
  offline for the whole removal can't tell the new keyring from one the removed device made up
  (as before: it knows only the old keys).
- **Secrets are plain files for the Mac app, and on Linux without a keyring** (#54). An `atdrive`
  built on its own keeps them in the login Keychain on a Mac; on Linux they're in the Secret
  Service where the session bus offers one. The Mac app, its extension and the `atdrive` inside
  it share `session.json` and `device.json` (mode 600) in the App Group container, and a Linux
  server without a desktop keeps them in `$XDG_STATE_HOME/atdrive`. Anything running as the user
  can read those. (They're never in `~/.config`, which people put in version control.) Remaining
  fix, with the iOS app: the Keychain for the Mac app. On macOS an App Group isn't a Keychain
  access group, so the three need a shared `keychain-access-groups` entitlement, which takes
  provisioning profiles. A server without a desktop has no Secret Service to use.

**Medium**

- **A device that never held the keys can't tell an encrypted drive from a plain one** (#35, new).
  The PDS decides what a new device sees first: shown plain settings, it would use the drive
  unencrypted, and what it writes would be readable. Nothing the new device can read settles it,
  so the user does: the first time a device opens a plain drive, `atdrive login` and the Mac app
  ask whether that's expected, and stop before writing anything if not (`Drive.plainDriveCheck`,
  remembered per device). They also point out a plain drive that still has device records.
  Accepted as the limit of trusting a PDS with first contact: someone who says yes without
  thinking, and a device that was offline while encryption was turned off and on again, which
  can be shown the old, genuine "off" settings.
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
- **Two devices changing the keys at the same moment** (#37). Turning encryption on: each made
  a keyring, and the last settings write won. Removing devices: two rotations could leave a
  device refusing its keyring, until the recovery key got it out. Fixed: every change to the
  settings creates a marker record keyed by the new generation and deletes the one it read,
  in the same transaction, which makes it a compare-and-swap (`Drive.applyChangingSettings`).
  The second device's write fails whole; it reads the drive again and decides again (turning
  encryption on: it's already on; rotating: it rotates from the first one's keys). The PDS can
  still delete markers, but that only brings back the race, which it could cause anyway by
  dropping writes.

**Low**

- **Settings sealed when encryption is turned on come from the plain record**, which the PDS
  could have changed beforehand. Fixed for the retention (#38): `encryption on` and the Mac app
  show the retention they'll seal, and one under a week is replaced by the default unless the
  user typed it (`--retention-days`). The rest (the drive ID, sharing fields) isn't something
  the PDS gains by changing.
- **Times come from device clocks** (#40: TIDs), and decide which side of a race lost and what
  pruning keeps. A device with a wrong clock, or a removed one, can skew both.
- **Device names were readable** on an encrypted drive (#39). Fixed: approving a device drops
  the name from its record; the one shown is sealed in its membership. A device's name is
  readable only while it waits to be approved (the approving device shows it beside the pairing
  code, which is what's compared). Records written before keep theirs until the next change of
  keys rewrites them.
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
- **Sign-in:** PKCE (S256), `state`, the issuer (`iss` is required in the redirect, and servers
  that don't promise it are refused, #34), that the token's `sub` is the account asked for,
  DPoP-bound tokens, the redirect listener on 127.0.0.1 only.
- **Files written:** permissions of the session, device identity and sync state; that keys,
  chunk IDs and recovery keys don't appear in logs or descriptions.

**Replacing the keys (#46).** `devices rm` and `encryption rotate` make a keyring of one new key,
retire the old ones (sealed in the settings, so only the drive's devices can read them) and
convert the drive as `encryption on` does, history included. A device takes a keyring missing
keys it knew only if the settings that keyring opens name those keys as retired or former, so
the removed device can't use this: it never had the new key, and a device that saw the removal
knows it. When the conversion is done, the retired keys are dropped and only their IDs and
fingerprints are kept. What anyone already downloaded or decrypted stays with them, and shared
folders keep their own keys.

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


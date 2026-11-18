# ATDrive: Dropbox on the ATmosphere

> [!WARNING]
> Warning: this tool is a proof of concept and seems to work but was totally vibe-coded. I am not a professional Swift developer. Also ATProto spaces are Alpha, so don't use this for data you care about. Just assume it _will_ be deleted at some point.

# Human-written

A cli and macOS app providing an iCloud-like experience using ATProto Spaces. The macOS app includes Apple File Provider support, so it plays nicely with Finder (and potentially the iOS files app if I ever decide to dig into that). In Finder, you can drag and drop files, move them, open in a terminal, etc. On linux, you can use the `atdrive sync` command to sync a folder (`~/atdrive` by default) and use it in the same way.

<img width="742" height="494" alt="macOS Finder Screenshot" src="https://github.com/user-attachments/assets/69353fcd-bd79-4906-ad38-7f70d043dc39" />

## Building & Running

Requires a Swift 6 toolchain: Xcode or the Command Line Tools on macOS,
[swift.org](https://www.swift.org/install/). There's also a `scripts/setup-swift.sh` command but I haven't tried it personally. Claude used it in its sandbox.

Build the cli:

```bash
scripts/build.sh
```

Then start the macOS Finder app with this command:
```bash
scripts/run-app.sh
```

A menubar item should appear. Click it and login with your handle. In Finder, you should now see an ATDrive Location next to iCloud Drive. You're done, start using it as sync/cloud storage!

## Usage

If you don't care about the Finder/macOS integration, you can also use the cli directly for everything. Here are some useful commands and examples:

```bash
# optionally copy the cli to somewhere on your path. Or just run commands with build/atdrive from the project root
cp build/atdrive ~/.local/bin/

atdrive login alice.example.com
atdrive login alice.example.com     # opens your browser to sign in
atdrive put -r ~/Documents/taxes /  # upload a folder
atdrive ls -l /taxes
atdrive tree
atdrive get /taxes/2026.pdf ~/Downloads/
atdrive mv /taxes /archive/taxes
atdrive rm -r /archive/taxes
```

| Command | What it does |
|---|---|
| `login <handle>` / `logout` / `whoami` | Start, end, or show the session |
| `ls [-l] [path]`, `tree [path]` | Browse the drive |
| `put [-r] <local>… [dest]` | Upload. Works like `cp`. Existing files are replaced in place, and unchanged ones are skipped |
| `get [-r] <path>… [local]` | Download. Works like `cp`. Files that are already identical locally are skipped |
| `cat <path>` | Print a file to stdout |
| `mkdir [-p] <path>…`, `mv <from> <to>`, `rm [-r] <path>…` | What you'd expect |
| `sync [folder]` | Keep a folder in sync with the drive (see [above](#a-synced-folder-linux)) |


<details>
<summary><h1>View Claude Slop</h1></summary>

# Claude Slop

A file drive that keeps your files in your own atproto account, privately, using
[atproto spaces](https://atproto.com/blog/atproto-spaces-alpha). On macOS the drive shows up in
Finder like iCloud Drive or Dropbox: files download when you open them and upload when you save.
On Linux (a desktop, or a server you SSH into), a folder like `~/atdrive` stays in sync with it.
On both there's also a command-line tool.

> **Alpha. Don't store anything irreplaceable.**
> - Spaces are an alpha protocol, and Bluesky's hosted alpha PDS may be wiped without warning.
> - Your drive is **not encrypted unless you turn encryption on**: by default, whoever runs your
>   PDS can read your files, as with most cloud drives. Turned on, only your devices can read
>   them, and you have keys to look after. You can switch either way at any time. See
>   [Encryption](#encryption).

## The Mac app (Finder)

Requires macOS 14+, Xcode or the Command Line Tools, and an **Apple Development certificate**.
A free Apple Developer account is enough: Xcode > Settings > Accounts > Manage Certificates >
\+ > Apple Development. macOS only lets signed apps add a drive to Finder.

```bash
scripts/run-app.sh
```

That builds `ATDrive.app`, installs it to `~/Applications`, and launches it.

1. Click the drive icon in the menu bar, enter your handle, and approve ATDrive on your account's
   sign-in page in the browser.
2. The first time, ATDrive asks whether to encrypt your new drive (see [Encryption](#encryption)),
   and shows the recovery key if you do. **Settings…** in the menu switches it later. If your
   drive is encrypted already, this Mac needs its keys first: approve it from a device that has
   them (comparing a code), or type the recovery key.
3. **ATDrive** appears in Finder's sidebar under Locations.
4. Drag files in, open them, rename them, delete them. Changes made elsewhere (another Mac, the
   CLI) show up within about 30 seconds.

Files are downloaded the first time you open them. Right-click > Remove Download frees the space
again. Changes made in two places at once are settled the same way as in a synced folder (see
[Conflicts](#conflicts)): no edit is lost.

`scripts/build-app.sh` builds the app without installing it. The top of the script lists its
signing options.

## A synced folder (Linux)

`atdrive sync` keeps a folder in sync with the drive in both directions, like a Dropbox folder.
Install the command-line tool (below), then:

```bash
atdrive login alice.example.com
```

The first time, that creates your drive (add `--encrypted` for an encrypted one, which shows its
recovery key). If the drive is encrypted, it also gets this computer the drive's keys (see
[Encryption](#encryption)). Then:

```bash
atdrive sync --install
```

That's it: work in `~/atdrive` as usual. Edit files in place, copy files in, and move, rename or
delete them; any program works, since they're ordinary files. Changes there reach the drive within
seconds. Changes made elsewhere (the Mac app, another computer, other `atdrive` commands) show up
within 30 seconds.

- **In the background:** `--install` sets up a systemd user service, so syncing keeps going after
  the terminal closes and starts again after a reboot. On a server you SSH into, also run
  `loginctl enable-linger` once, so it keeps running while you're logged out.
  - `journalctl --user -u atdrive-sync -f` shows what it's doing.
  - `atdrive sync --uninstall` stops it. The folder and the drive are left as they are.
- **In the foreground:** `atdrive sync [folder]` syncs until you press Ctrl-C (the default folder
  is `~/atdrive`), and `atdrive sync --once` syncs once and exits.
- **Signing in over SSH:** `atdrive login` prints a link to open in a browser on any device, then
  you paste back the address the browser ends up on (see *Signing in on a remote machine* below).
  Sessions last two weeks; when one expires, the service waits until you `atdrive login` again,
  then carries on. It also waits while this computer doesn't have an encrypted drive's keys
  (say another device just turned encryption on). It never creates a drive: only `atdrive login`
  does.
- **Starting with files in the folder** is fine: the folder and the drive are merged. Matching
  files and folders are paired up, and nothing is deleted.
- **Conflicts** are settled the same way as on the Mac (see [Conflicts](#conflicts)): no edit is
  lost.
- **What isn't synced:** symlinks and other special files, and clutter: `.DS_Store`,
  `Thumbs.db`, and the swap and lock files editors leave around (Vim, Emacs, LibreOffice, Office).
  Files are synced once they've stopped changing for a couple of seconds.
- **Safety:** the sync keeps its own state in `~/atdrive/.atdrive`. If the folder disappears (say,
  a disk that's no longer mounted), syncing stops rather than deleting things from the drive.
  Deleting `.atdrive` starts over with a merge.

The folder holds a full copy of the drive. On a Mac, use the app instead: Finder downloads files
only when you open them.

## The command line (macOS and Linux)

Requires a Swift 6 toolchain: Xcode or the Command Line Tools on macOS,
[swift.org](https://www.swift.org/install/) on Linux.

```bash
scripts/build.sh
```

```bash
cp build/atdrive ~/.local/bin/
```

```bash
atdrive login alice.example.com     # opens your browser to sign in
atdrive put -r ~/Documents/taxes /  # upload a folder
atdrive ls -l /taxes
atdrive tree
atdrive get /taxes/2026.pdf ~/Downloads/
atdrive mv /taxes /archive/taxes
atdrive rm -r /archive/taxes
```

| Command | What it does |
|---|---|
| `login <handle>` / `logout` / `whoami` | Start, end, or show the session. `login` also creates the drive (asking whether to encrypt it), or gets this device its keys |
| `ls [-l] [path]`, `tree [path]` | Browse the drive |
| `put [-r] <local>… [dest]` | Upload. Works like `cp`. Existing files are replaced in place, and unchanged ones are skipped |
| `get [-r] <path>… [local]` | Download. Works like `cp`. Files that are already identical locally are skipped. Also takes a share link |
| `cat <path>` | Print a file to stdout |
| `mkdir [-p] <path>…`, `mv <from> <to>`, `rm [-r] <path>…` | What you'd expect. `rm` puts things in the trash |
| `sync [folder]` | Keep a folder in sync with the drive (see [claude notes here](#a-synced-folder-linux)) |
| `share <path> [people…]`, `unshare <path> [people…]` | Share with people, or naming nobody, with a public link; take people off, or naming nobody, stop sharing (see [Sharing](#sharing)) |
| `shares`, `open-share <link>`, `verify <person>` | What you share and what's shared with you; put something shared with you in your drive; check someone's key |
| `ls`, `tree`, `get`, `cat` with `--at <when>` | The drive as it was then (see [History and trash](#history-and-trash)) |
| `history [path]` | What changed, when, and on which device: for a file, a folder, or the whole drive |
| `restore <path> [--at <when>]` | Bring something back from the trash, or undo its latest change; with `--at`, as it was then |
| `trash`, `trash empty [path…]` | What was deleted in the last 30 days; delete it (or just these) for good, with its history |
| `encryption`, `encryption on`, `encryption off` | Whether the drive is encrypted, and turning encryption on or off (see [Encryption](#encryption)) |
| `encryption unlock`, `encryption rotate-recovery-key` | Give this device the drive's keys with the recovery key; replace the recovery key |
| `devices`, `devices approve [name]`, `devices rm <name>` | An encrypted drive's devices; give a new one the keys (after comparing a code), or take one off |
| `dev reset`, `dev du`, `dev lexicons publish` | For development: delete everything, as if ATDrive had never been used; space used by files and history; publish the schemas |

Paths in the drive always start from the top (`/photos/cat.jpg`).

**Signing in.** ATDrive uses atproto OAuth: you sign in on your own PDS's page in the browser,
and ATDrive never sees your password.
- **What it gets:** tokens that are tied to a key only it holds, saved in
  `~/.config/atdrive/session.json` (mode 600) for the CLI, or in the app's container on the Mac.
- **Then it opens your drive:** the first `atdrive login` creates it, asking whether to encrypt
  it (an encrypted drive's recovery key is shown then). For an encrypted drive this device doesn't have the
  keys of yet, it asks how to get them (see [Encryption](#encryption)).
- **What it keeps beside them, for an encrypted drive:** this device's own key pair, which the
  drive's keys are wrapped for (`device.json`, also mode 600). `atdrive logout` leaves it, so
  signing in again on the same device doesn't need another approval.
- **What it asks for:**
  - writes only to ATDrive's own records;
  - creating its space;
  - uploading file contents;
  - read access to the private spaces you own. This is broader than ATDrive needs, until
    its schema is published (see PLAN.md).
- **Sessions last two weeks.** That's the limit Bluesky's servers set for apps without a
  backend. After that, sign in again.

**Signing in on a remote machine** (over SSH, or a server without a desktop) uses the same
command. `atdrive login` prints a link to open in a browser on any device. After you approve, the
browser lands on a page that won't load, at an address starting with `http://127.0.0.1`. Paste that
address back into the terminal and you're signed in.

Signing in is always through the browser: atproto spaces don't accept app passwords.

## History and trash

The drive keeps 30 days of history: every edit, rename, move and delete, wherever it was made
(Finder, a synced folder, the command line), and which device made it.

```bash
atdrive history /docs/notes.txt             # its changes, newest first
atdrive cat /docs/notes.txt --at 2d         # as it was two days ago
atdrive restore /docs/notes.txt             # undo its latest change
atdrive restore /docs --at 3d               # a folder as it was 3 days ago
atdrive trash                               # what was deleted
atdrive restore /photos                     # bring it back from the trash
```

- **`--at <when>`** works with `ls`, `tree`, `get`, `cat` and `restore`. It takes `2h` or `3d`
  (that long ago), a day (`2026-11-08`, from midnight, local time), a time (`2026-11-08T14:00`),
  or a version ID from `atdrive history`. Paths are looked up as of then, so something renamed
  or moved since is found under its old path.
- **Restoring** puts back contents, name and place. A folder gets back what was in it then, and
  keeps what was added since. A restore is a change like any other, so it can be undone too.
- **The trash** holds what was deleted in the last 30 days. `restore` brings something deleted
  back where it was, with the folders it was in. If the name is taken by now, it comes back as a
  conflicted copy. (On something that isn't deleted, `restore` without `--at` undoes its latest
  change. It says which it did.)
- **For good:** `atdrive trash empty` deletes everything in the trash, with all its history, and
  `trash empty <path>` just that. To get rid of something right away, `rm` it, then `trash empty`
  it. It asks first (`--yes` skips the question).
- **Two devices changing the same file at once** don't lose an edit: both versions are kept, and
  `history` marks the one that "lost a race". Syncing brings a lost edit back as a conflicted copy.
- **Space:** history costs only what changed, since a chunk is stored once however many files and
  versions use it. `atdrive dev du` shows how much is current files and how much is history.
  `atdrive sync` and the Mac app delete history older than 30 days once a day.

Times come from the clock of the device that made the change.

## Encryption

Encryption is optional, and off unless you turn it on.

- **Off (the default):** your PDS stores your files and their names as they are. Whoever runs it
  can read them, as with Dropbox or Google Drive, and nobody else can (the drive is private to
  your account). There are no keys: any device you sign in on can use the drive, and there's
  nothing to lose.
- **On:** your devices encrypt everything before it leaves them. Your PDS stores only what it
  can't read, so whoever runs it can't see your files, their names or the folders they're in. In
  exchange you have keys to look after: each new device has to be approved, and losing every
  device and the recovery key loses the drive.

```bash
atdrive encryption        # which it is, and whether anything is still being converted
atdrive encryption on     # (a new drive asks when it's created)
atdrive encryption off
```

On a Mac, the same switch is in the app's **Settings…**.

- **Turning it on** makes new keys and shows a recovery key, then uploads every file again,
  encrypted, history included. On a big drive that takes a while and a lot of transfer; it says
  how much before it starts. It can be interrupted: `atdrive encryption on` again picks up where
  it stopped, and until it's done your devices read both kinds. Your other devices have to be
  approved again. Whoever runs your PDS could read what was there until then: this protects it
  from then on, not from copies already made.
- **Turning it off** is immediate: the drive's keys are published in the drive itself, so
  everything in it, history included, is readable by whoever runs your PDS from that moment. That
  can't be taken back for what's already there. The files are then uploaded again unencrypted, so
  apps that can't decrypt can read them; that part can be interrupted. Your other devices carry on by themselves: they recognize the published keys, so
  they know it was one of your devices that turned encryption off, not the server.

The rest of this section is about encrypted drives.

- **The recovery key** is shown once, when the drive is created: 14 groups of 4 letters and
  digits. Write it down, or keep it in a password manager. With it, any device you sign in on can
  open the drive (`atdrive encryption unlock`). **If you lose every device that has the drive's
  keys and the recovery key too, nobody can read your files again**: not you, and not whoever runs
  your PDS. `atdrive encryption rotate-recovery-key` makes a new one; the old one stops working.
- **Adding a device:** sign in there (`atdrive login`, or the Mac app). Then either type the
  recovery key, or approve it from a device that has the keys:

  ```bash
  atdrive devices approve server      # on your laptop
  ```

  Both devices show a 16-digit code. Approve only if they match: if they don't, something between
  them swapped in a key of its own. The new device then shows the code of the one that approved
  it, to confirm once more.
- **Removing a device** (`atdrive devices rm <name>`, say for a lost laptop) gives the drive
  a new key for everything written from then on, which the removed device never gets. It asks for
  the recovery key, which has to open the new key too (or makes a new recovery key). What removal
  can't do:
  - The removed device can still read everything stored before, and keeps its own copies.
    Re-encrypting what's stored under a new key is planned (#46).
  - It can still sign in to your account until you revoke its session (in your account's settings,
    or by signing it out there). Until every other device has seen the removal, what it
    writes may still be read.
- **What the PDS still sees:** how many files and folders there are, roughly how big each file
  is, when things are created and changed, which files share contents, and your devices' names.
  It can't read or change your files without it showing, but it can delete them, or serve an older
  copy of the drive.
- **What the PDS can't do** is switch encryption off behind your back. A device that has held the
  drive's keys believes the drive stopped being encrypted only if the drive publishes those keys,
  which the PDS never had. Otherwise it refuses to write anything, and says why.

## Sharing

Share a file or folder with specific people, or with anyone who has its link. Read-only for
them: they see it in their own drive (in Finder, or a synced folder), kept up to date.

In Finder, right-click: **Share…** (who has it, and the link), **Copy Link**, **Stop Sharing**.
Shared things have a badge. Clicking an `atdrive://` link opens ATDrive, with **Add to My Drive**
and **Download…**; so does **Add Shared Link…** in the menu bar.

From the command line:

```bash
atdrive share /photos alice.bsky.social      # share it with alice
atdrive share /photos                        # a public link anyone can open (prints it)
atdrive shares                               # what you share, with whom, and its link; and what's shared with you
atdrive unshare /photos alice.bsky.social    # take alice off
atdrive unshare /photos                      # stop sharing it: it's an ordinary folder again

atdrive open-share 'atdrive://open?at=…'     # put something shared with you in your drive
atdrive get 'atdrive://open?at=…' ~/Downloads   # just download it (no sign-in needed for a link)
atdrive rm /from-alice                       # take something shared with you out of your drive
```

- **The first time something is shared,** it moves into a space of its own, which stays where it
  was in your drive. Its history up to then stays with your drive: people see it from then on.
  Once nobody has it any more (no people, no link), it's an ordinary file or folder again.
- **Shares take your drive's mode.** An encrypted drive's shares are encrypted, even behind a
  link: an encrypted share's link ends with `#<key>`, which never reaches a server.
- **Sharing encrypted files with someone** wraps the share's keys for the sharing key they
  publish. To be sure it's really theirs, compare codes: `atdrive verify <handle>`. If their
  key changes later, you're asked before anything new is shared with them. If their own drive
  isn't encrypted, you're told: their PDS could read what you share.
- **Taking someone off** stops them getting anything new; what they already downloaded stays theirs.
- **Deleting something you share** (`rm`) stops sharing it; it asks first, and says who loses it.
- **If you lose access** to something shared with you, it stays as it was, and says why. If its
  owner deletes it, it's gone here too.
- **Turning encryption on or off ends your sharing:** your shares move back into your drive, and
  you share them again afterwards.
- **Links need ATDrive to open them.** `atdrive sync --install` makes ATDrive open `atdrive://`
  links on a Linux desktop; the Mac app does on a Mac. Some chat apps won't make them clickable:
  paste them into ATDrive instead.

To start over while trying things out, `atdrive dev reset` deletes your whole drive (and
everything you shared), as if ATDrive had never been used on your account. The next sign-in makes
a new drive, and asks whether to encrypt it.

## Conflicts

When something changes in two places before they sync (say, on the Mac and on a server), every
device settles it the same way. The Mac app and `atdrive sync` share these rules
(`ConflictRules` in the code):

- **Edited in both places:** the drive's version keeps the name, and yours is saved beside it as
  `name (conflicted copy <date>).ext`. If both edits came out identical, there's nothing to do.
- **Moved or renamed in both places:** the drive's move wins (it's the one other devices already
  see).
- **Deleted in one place, edited in the other:** the edit is kept. Moving or renaming it doesn't
  count as an edit: the delete goes ahead.
- **A folder deleted in one place** keeps whatever was added to it, moved into it or edited in it
  elsewhere in the meantime. Everything else in it is deleted.
- **Two different things given the same name:** the second one to arrive is renamed
  `name (conflicted copy <date>)`. Two identical ones (two folders, or two files with the same
  contents) become one.

## How it works

- **Your drive is one space:** `at://<your-did>/space/me.jsnelgro.atdrive.drive/default`. It uses
  the `personalspace` policy, so only your account can read or write it.
- **Each file or folder is one record** (`me.jsnelgro.atdrive.node`, see [`lexicons/`](lexicons)).
  A record names its parent folder by ID rather than storing a path, so a rename or move is one
  small update, however much a folder contains. Every change also writes a version record: the
  history.
- **Each record is plain or sealed,** and says which, so a drive can hold both while encryption
  is being turned on or off. The drive's settings record says which the drive is.
  - **Plain:** the record's fields as they are, and the file's bytes in blobs.
  - **Sealed:** all a record holds that the PDS doesn't need (name, folder, size, hash, times,
    and the keys to its chunks) is encrypted with AES-GCM under the drive's key, and bound to
    that record in that drive, so the PDS can't move it to another one. Only the references to
    the file's chunks stay readable, so the PDS keeps them.
- **File contents are stored as blobs,** in chunks of about 1 MiB (256 KiB to 4 MiB). Where a
  chunk ends depends on the bytes around it (content-defined chunking, FastCDC), so an edit or
  an insert changes the chunk or two around it, not every chunk after it. On an encrypted drive,
  where the cuts go is keyed by the drive, so chunk sizes don't give away which files you have.
- **Only what changed moves.** Identical chunks are identical blobs, which are stored once. On
  an encrypted drive that still holds: a chunk's key comes from its contents and the drive key
  (as in Tahoe-LAFS and borg), and without the drive key nobody can tell what a chunk holds.
  - **Uploads** skip the chunks the drive already has: a new version costs what changed, and a
    copy of a file costs nothing.
  - **Downloads** use what the copy you have already holds (the synced file, or the file
    `atdrive get` replaces), and fetch only the rest.
  - Four chunks move at once. Each is checked against its content ID (CID) and decrypted, and
    each downloaded file against its SHA-256. A file changes on the drive only once all of its
    chunks are there, so an interrupted upload leaves the version before.
- **Big files:** a record holds the chunk list of about 2 GB. A longer one continues in
  `me.jsnelgro.atdrive.chunks` records that belong to the file's version, and go when it does.
- **Keys** (encrypted drives): the drive key is random, made when encryption is turned on. Each
  device has its own key pair, and its own record in the drive (`me.jsnelgro.atdrive.device`)
  with the drive's keys wrapped for it; one more wraps them for the recovery key. A device takes keys only from itself,
  from the device whose code you compared, or from another device you approved; so the PDS can't
  slip it a key of its own.
- **Nothing about your account is hardcoded.** Your handle resolves to your DID, and your DID
  resolves to your PDS, the same way every atproto app does it. Optional overrides:

  | Variable | Default |
  |---|---|
  | `ATDRIVE_CONFIG_DIR` | `~/.config/atdrive` (or `$XDG_CONFIG_HOME/atdrive`) |
  | `ATDRIVE_PLC_URL` | `https://plc.directory` |
  | `ATDRIVE_HANDLE_RESOLVER` | `https://public.api.bsky.app` (used when a handle has no `/.well-known/atproto-did`) |

## Development

```bash
scripts/test.sh                       # unit tests (no network)
```

```bash
scripts/format.sh
```

Live tests against a real spaces PDS:

```bash
ATDRIVE_LIVE_HANDLE=you.spaces-alpha.bsky.network scripts/test.sh --filter OAuthLiveTests
```

```bash
ATDRIVE_CONFIG_DIR=~/.atdrive-live-a atdrive login you.spaces-alpha.bsky.network
ATDRIVE_LIVE_CONFIG=~/.atdrive-live-a scripts/test.sh --filter Live
```

- `OAuthLiveTests` starts a real OAuth sign-in and checks the server accepts it, up to the point
  where a person would approve it.
- The other live tests use the session `atdrive login` saved in `ATDRIVE_LIVE_CONFIG` (sign in
  into a folder of its own with `ATDRIVE_CONFIG_DIR`, as above). `LiveTests` runs a full
  upload/download round trip, and `LiveChangeFeedTests` follows the change feed. Both clean up
  after themselves. It creates the account's drive if there's none (plain); for an account whose drive
  is encrypted, set `ATDRIVE_LIVE_RECOVERY_KEY` to its recovery key (each run then adds a device
  to the drive).

Mac app logs (app and extension):

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "me.jsnelgro.atdrive"'
```

See [PLAN.md](PLAN.md) for the roadmap and design notes.

## Current limitations

- **One drive per account.** The Mac app and the CLI each keep their own login.
- **Sharing is read-only.** Folders others can edit come later (#25). Shared folders can't go
  inside each other.
- **Remote changes are polled** every 30 seconds, not pushed.
- **`put`, `mv` and `rm` have no conflict detection: the last write wins.** The spaces alpha has
  no compare-and-swap for writes. What was overwritten stays in history, though, and `atdrive sync`
  and the Mac app bring a lost edit back as a conflicted copy.
- **Files transfer one at a time.** Each moves a few chunks at once, but while a big one
  transfers, other changes wait.
- **On the Mac, a file that changed elsewhere is downloaded whole.** Uploads from the Mac skip
  what the drive has, but the extension doesn't yet get Finder's old copy to reuse.
- **`atdrive sync` on a Mac** works, but two names that differ only in case (`Notes.txt` and
  `notes.txt`) clash on Mac disks. The app doesn't have this problem.
- **History and the trash are only in the command line.** Things deleted in Finder or in a
  synced folder still go to the trash, and `atdrive restore` brings them back.
- **Symlinks and aliases aren't stored.**
- **Approving and removing devices is only in the command line.** The Mac app can create a drive
  (encrypted or not), switch encryption, and join an encrypted drive (by approval or the recovery
  key).
- **A device that was offline when encryption was turned on** may write a few unencrypted
  records before it notices. Encrypted devices ignore those (the server could have written
  them) until you run `atdrive encryption on` again, which offers to encrypt and keep them.
- **Removing a device doesn't sign it out of your account.** Revoke its session in your
  account's settings too. See [Encryption](#encryption) for what removal does and doesn't do.
- **Device names aren't encrypted,** even on an encrypted drive: the PDS sees what your devices
  are called.

</details>

# ATDrive: Dropbox on the ATmosphere

> [!WARNING]
> Warning: this tool is a proof of concept and seems to work but was totally vibe-coded. I am not a professional Swift developer. Also ATProto spaces are Alpha, so don't use this for data you care about. Just assume it _will_ be deleted at some point.

## Human-written

A cli and macOS app providing an iCloud-like experience using ATProto Spaces. The macOS app includes Apple File Provider support, so it plays nicely with Finder (and potentially the iOS files app if I ever decide to dig into that). In Finder, you can drag and drop files, move them, open in a terminal, etc. On linux, you can use the `atdrive sync` command to sync a folder (`~/atdrive` by default) and use it in the same way.

<img width="742" height="494" alt="macOS Finder Screenshot" src="https://github.com/user-attachments/assets/69353fcd-bd79-4906-ad38-7f70d043dc39" />


# Claude Slop

A file drive that keeps your files in your own atproto account, privately, using
[atproto spaces](https://atproto.com/blog/atproto-spaces-alpha). On macOS the drive shows up in
Finder like iCloud Drive or Dropbox: files download when you open them and upload when you save.
On Linux (a desktop, or a server you SSH into), a folder like `~/atdrive` stays in sync with it.
On both there's also a command-line tool.

> **Alpha. Don't store anything irreplaceable.**
> - Spaces are an alpha protocol, and Bluesky's hosted alpha PDS may be wiped without warning.
> - Your drive is **encrypted on your devices**: whoever runs your PDS can't read your files or
>   their names. It can still see roughly how much you store and when it changes, and it could
>   delete things. See [Encryption](#encryption).

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
2. The first time, ATDrive creates your drive and shows its **recovery key**. Save it before you
   click "I've Saved It" (see [Encryption](#encryption)). If your drive was made on another
   device, this Mac needs its keys first: approve it from a device that has them (comparing a
   code), or type the recovery key.
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

The first time, that creates your drive and shows its recovery key; on another computer, it gets
this one the drive's keys (see [Encryption](#encryption)). Then:

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
  then carries on. It also waits while this computer doesn't have the drive's keys. It never
  creates a drive: only `atdrive login` does, since it has a recovery key to show.
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
| `login <handle>` / `logout` / `whoami` | Start, end, or show the session. `login` also creates the drive, or gets this device its keys |
| `ls [-l] [path]`, `tree [path]` | Browse the drive |
| `put [-r] <local>… [dest]` | Upload. Works like `cp`. Existing files are replaced in place, and unchanged ones are skipped |
| `get [-r] <path>… [local]` | Download. Works like `cp`. Files that are already identical locally are skipped |
| `cat <path>` | Print a file to stdout |
| `mkdir [-p] <path>…`, `mv <from> <to>`, `rm [-r] <path>…` | What you'd expect. `rm` puts things in the trash |
| `sync [folder]` | Keep a folder in sync with the drive (see [above](#a-synced-folder-linux)) |
| `ls`, `tree`, `get`, `cat` with `--at <when>` | The drive as it was then (see [History and trash](#history-and-trash)) |
| `history [path]` | What changed, when, and on which device: for a file, a folder, or the whole drive |
| `restore <path> --at <when>` | Put a file or folder back as it was then: contents, name and place |
| `restore <path> --previous` | Undo its latest change |
| `trash`, `trash restore <path>…` | What was deleted in the last 30 days, and bring it back where it was |
| `trash empty`, `purge [-r] <path>…` | Delete everything in the trash, or anything, for good, with its history |
| `du` | Space used by current files and by history |
| `prune` | Delete history older than 30 days now (`sync` does it once a day) |
| `devices` | The devices that hold the drive's keys, and those asking for them |
| `devices approve [name]`, `devices remove <name>` | Give a new device the keys (after comparing a code), or take a device's access away (see [Encryption](#encryption)) |
| `unlock` | Give this device the drive's keys with the recovery key |
| `recovery-key` | Make a new recovery key. The old one stops working |

Paths in the drive always start from the top (`/photos/cat.jpg`).

**Signing in.** ATDrive uses atproto OAuth: you sign in on your own PDS's page in the browser,
and ATDrive never sees your password.
- **What it gets:** tokens that are tied to a key only it holds, saved in
  `~/.config/atdrive/session.json` (mode 600) for the CLI, or in the app's container on the Mac.
- **What it keeps beside them:** this device's own key pair, which the drive's keys are wrapped
  for (`device.json`, also mode 600). `atdrive logout` leaves it, so signing in again on the same
  device doesn't need another approval.
- **Then it gets the drive's keys:** the first `atdrive login` creates your drive and shows its
  recovery key. On a device that doesn't have the keys yet, it asks how to get them (see
  [Encryption](#encryption)).
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

For scripts, `atdrive login --app-password <handle>` signs in with an app password instead.

## History and trash

The drive keeps 30 days of history: every edit, rename, move and delete, wherever it was made
(Finder, a synced folder, the command line), and which device made it.

```bash
atdrive history /docs/notes.txt             # its changes, newest first
atdrive cat /docs/notes.txt --at 2d         # as it was two days ago
atdrive restore /docs/notes.txt --previous  # undo its latest change
atdrive restore /docs --at 3d               # a folder as it was 3 days ago
atdrive trash                               # what was deleted
atdrive trash restore /photos               # bring it back
```

- **`--at <when>`** works with `ls`, `tree`, `get`, `cat` and `restore`. It takes `2h` or `3d`
  (that long ago), a day (`2026-11-08`, from midnight, local time), a time (`2026-11-08T14:00`),
  or a version ID from `atdrive history`. Paths are looked up as of then, so something renamed
  or moved since is found under its old path.
- **Restoring** puts back contents, name and place. A folder gets back what was in it then, and
  keeps what was added since. A restore is a change like any other, so it can be undone too.
- **The trash** holds what was deleted in the last 30 days. `trash restore` brings something back
  where it was, with the folders it was in. If the name is taken by now, it comes back as a
  conflicted copy.
- **For good:** `atdrive purge` deletes something now, with all its history, and `trash empty` does
  that to everything in the trash. Both ask first (`--yes` skips the question).
- **Two devices changing the same file at once** don't lose an edit: both versions are kept, and
  `history` marks the one that "lost a race". Syncing brings a lost edit back as a conflicted copy.
- **Space:** history costs only what changed, since a chunk is stored once however many files and
  versions use it. `atdrive du` shows how much is current files and how much is history.
  `atdrive sync` deletes history older than 30 days once a day; `atdrive prune` does it now.

Times come from the clock of the device that made the change.

## Encryption

Your drive is encrypted on your devices, always: there's no unencrypted mode. Your PDS stores
only what it can't read, so whoever runs it can't see your files, their names or the folders
they're in.

- **The recovery key** is shown once, when the drive is created: 14 groups of 4 letters and
  digits. Write it down, or keep it in a password manager. With it, any device you sign in on can
  open the drive (`atdrive unlock`). **If you lose every device that has the drive's keys and the
  recovery key too, nobody can read your files again**: not you, and not whoever runs your PDS.
  `atdrive recovery-key` makes a new one; the old one stops working.
- **Adding a device:** sign in there (`atdrive login`, or the Mac app). Then either type the
  recovery key, or approve it from a device that has the keys:

  ```bash
  atdrive devices approve server      # on your laptop
  ```

  Both devices show a 16-digit code. Approve only if they match: if they don't, something between
  them swapped in a key of its own. The new device then shows the code of the one that approved
  it, to confirm once more.
- **Removing a device** (`atdrive devices remove <name>`, say for a lost laptop) gives the drive
  a new key for everything written from then on, which the removed device never gets. It asks for
  the recovery key, which has to open the new key too (or makes a new recovery key). What removal
  can't do:
  - The removed device keeps what it could already read: everything written before, and its own
    copies.
  - It can still sign in to your account until you revoke its session (in your account's settings,
    or by deleting its app password). Until every other device has seen the removal, what it
    writes may still be read.
- **What the PDS still sees:** how many files and folders there are, roughly how big each file
  is, when things are created and changed, which files share contents, and your devices' names.
  It can't read or change your files without it showing, but it can delete them, or serve an older
  copy of the drive.

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
- **Records are sealed.** All a record holds that the PDS doesn't need (name, folder, size,
  hash, times, and the keys to its chunks) is encrypted with AES-GCM under the drive's key, and
  bound to that record, so the PDS can't move it to another one. Only the references to the
  file's chunks stay readable, so the PDS keeps them.
- **File contents are stored as encrypted blobs,** in chunks of about 1 MiB (256 KiB to 4 MiB).
  Where a chunk ends depends on the bytes around it (content-defined chunking, FastCDC), so an
  edit or an insert changes the chunk or two around it, not every chunk after it. Where the cuts
  go is keyed by the drive, so chunk sizes don't give away which files you have.
- **Only what changed moves.** A chunk's key comes from its contents and the drive key (as in
  Tahoe-LAFS and borg), so identical chunks encrypt to identical blobs, which are stored once;
  without the drive key nobody can tell what they hold.
  - **Uploads** skip the chunks the drive already has: a new version costs what changed, and a
    copy of a file costs nothing.
  - **Downloads** use what the copy you have already holds (the synced file, or the file
    `atdrive get` replaces), and fetch only the rest.
  - Four chunks move at once. Each is checked against its content ID (CID) and decrypted, and
    each downloaded file against its SHA-256. A file changes on the drive only once all of its
    chunks are there, so an interrupted upload leaves the version before.
- **Big files:** a record holds the chunk list of about 2 GB. A longer one continues in
  `me.jsnelgro.atdrive.chunks` records that belong to the file's version, and go when it does.
- **Keys:** the drive key is random, made when the drive is created. Each device has its own key
  pair, and its own record in the drive (`me.jsnelgro.atdrive.device`) with the drive's keys
  wrapped for it; one more wraps them for the recovery key. A device takes keys only from itself,
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
ATDRIVE_LIVE_HANDLE=you.spaces-alpha.bsky.network ATDRIVE_LIVE_PASSWORD=xxxx-xxxx-xxxx-xxxx scripts/test.sh --filter LiveTests
```

- `OAuthLiveTests` needs no password. It starts a real OAuth sign-in and checks the server accepts
  it, up to the point where a person would approve it.
- `LiveTests` runs a full upload/download round trip using an app password, and cleans up after
  itself. It creates the account's drive if there's none; for an account that has one, set
  `ATDRIVE_LIVE_RECOVERY_KEY` to its recovery key (each run then adds a device to the drive).

Mac app logs (app and extension):

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "me.jsnelgro.atdrive"'
```

See [PLAN.md](PLAN.md) for the roadmap and design notes.

## Current limitations

- **One drive per account.** The Mac app and the CLI each keep their own login.
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
  synced folder still go to the trash, and `atdrive trash restore` brings them back.
- **Symlinks and aliases aren't stored.**
- **Approving and removing devices is only in the command line.** The Mac app can join a drive
  (by approval or the recovery key) and create one, but not approve or remove other devices yet.
- **Removing a device doesn't sign it out of your account.** Revoke its session in your
  account's settings too. See [Encryption](#encryption) for what removal does and doesn't do.
- **Device names aren't encrypted:** the PDS sees what your devices are called.

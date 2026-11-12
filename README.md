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
> - Your drive is **encrypted on your devices**, so whoever runs your PDS can't read your files or
>   their names. Your passkey is the only way to open it: lose every copy of the passkey and the
>   drive can't be opened again (see [Encryption](#encryption)).

## The Mac app (Finder)

Requires macOS 14+, Xcode or the Command Line Tools, and an **Apple Development certificate**.
A free Apple Developer account is enough: Xcode > Settings > Accounts > Manage Certificates >
\+ > Apple Development. macOS only lets signed apps add a drive to Finder.

```bash
scripts/run-app.sh
```

That builds `ATDrive.app`, installs it to `~/Applications`, and launches it.

1. Click the drive icon in the menu bar, enter your handle, and approve ATDrive on your account's
   sign-in page in the browser. The browser then asks for your passkey to unlock your drive (the
   first time, it makes one).
2. **ATDrive** appears in Finder's sidebar under Locations.
3. Drag files in, open them, rename them, delete them. Changes made elsewhere (another Mac, the
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
  then carries on.
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
| `login <handle>` / `logout` / `whoami` | Start, end, or show the session |
| `ls [-l] [path]`, `tree [path]` | Browse the drive |
| `put [-r] <local>… [dest]` | Upload. Works like `cp`. Existing files are replaced in place, and unchanged ones are skipped |
| `get [-r] <path>… [local]` | Download. Works like `cp`. Files that are already identical locally are skipped |
| `cat <path>` | Print a file to stdout |
| `mkdir [-p] <path>…`, `mv <from> <to>`, `rm [-r] <path>…` | What you'd expect |
| `sync [folder]` | Keep a folder in sync with the drive (see [above](#a-synced-folder-linux)) |

Paths in the drive always start from the top (`/photos/cat.jpg`).

**Signing in.** ATDrive uses atproto OAuth: you sign in on your own PDS's page in the browser,
and ATDrive never sees your password. The browser then goes on to a page that asks for your
passkey, which unlocks your drive (see [Encryption](#encryption)).
- **What it gets:** tokens that are tied to a key only it holds, and your drive's key, saved in
  `~/.config/atdrive/session.json` (mode 600) for the CLI, or in the app's container on the Mac.
  `atdrive logout` deletes both.
- **What it asks for:**
  - writes only to ATDrive's own records;
  - creating its space;
  - uploading file contents;
  - read access to the private spaces you own. This is broader than ATDrive needs, until
    its schema is published (see PLAN.md).
- **Sessions last two weeks.** That's the limit Bluesky's servers set for apps without a
  backend. After that, sign in again.

**Signing in on a remote machine** (over SSH, or a server without a desktop) uses the same
command. `atdrive login` prints a link to open in a browser on any device, your phone included.
After you approve, the browser lands on a page that won't load, at an address starting with
`http://127.0.0.1`. Paste that address back into the terminal. Then it does the same for your
passkey: open the second link, use your passkey, and paste the address back again.

For scripts, `atdrive login --app-password <handle>` signs in with an app password instead. The
drive is still unlocked with your passkey, in the browser.

## Encryption

Your drive is encrypted before anything leaves your device. Your PDS stores only what it can't
read: whoever runs it can't see your files, their names, or which folder they're in.

There are no keys to manage. The first time you sign in, your browser makes a **passkey** for
ATDrive, and your drive's key is locked with it. Passkeys sync like passwords (iCloud Keychain,
Google Password Manager, 1Password, …), so on your other devices signing in is just Face ID,
Touch ID or your phone. On a computer that doesn't have your passkey, most browsers can use the
one on your phone instead (they show a QR code).

- **Keep your passkey.** It's the only way to open your drive. If you lose every copy of it,
  nobody can read your files again: not you, and not whoever runs your PDS. Deleting it from your
  password manager does that too.
- **What the PDS still sees:** how many files and folders there are, roughly how big each file is,
  and when things are created and changed. It can't read or change your files without it showing,
  but it can delete them.
- **Drives from before encryption** are encrypted the next time you sign in.

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
  small update, however much a folder contains.
- **File contents are stored as blobs** in 4 MiB chunks. Each chunk is checked against its content
  ID (CID), and each downloaded file is checked against its SHA-256.
- **Encryption:** each record's name, folder, size and hash are sealed with AES-256-GCM, and so is
  every chunk, under keys derived from your drive's key. The drive key is stored on the PDS only
  wrapped by your passkey (`me.jsnelgro.atdrive.key`), using the WebAuthn PRF extension. The
  passkey prompt runs on a small static page ([`web/unlock/`](web/unlock)), because apps can't use a
  website's passkeys; it hands the result back to ATDrive on 127.0.0.1, sealed to a one-time key.
- **Nothing about your account is hardcoded.** Your handle resolves to your DID, and your DID
  resolves to your PDS, the same way every atproto app does it. Optional overrides:

  | Variable | Default |
  |---|---|
  | `ATDRIVE_CONFIG_DIR` | `~/.config/atdrive` (or `$XDG_CONFIG_HOME/atdrive`) |
  | `ATDRIVE_PLC_URL` | `https://plc.directory` |
  | `ATDRIVE_HANDLE_RESOLVER` | `https://public.api.bsky.app` (used when a handle has no `/.well-known/atproto-did`) |
  | `ATDRIVE_UNLOCK_PAGE` | `https://atdrive.jsnelgro.me/unlock/` (the passkey page; passkeys belong to its host name) |

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
  itself. It uses a separate drive (`live-test`) with a key made from the password, so it needs
  no passkey and doesn't touch your real drive.

The unlock page is static: serve [`web/`](web) at the address in `ATDRIVE_UNLOCK_PAGE`. Passkeys
are tied to its host name, so changing the host later means making new ones. To try it locally,
serve `web/` on `http://localhost:<port>` and point `ATDRIVE_UNLOCK_PAGE` at
`http://localhost:<port>/unlock/`.

Mac app logs (app and extension):

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "me.jsnelgro.atdrive"'
```

See [PLAN.md](PLAN.md) for the roadmap and design notes.

## Current limitations

- **One drive per account.** The Mac app and the CLI each keep their own login.
- **Remote changes are polled** every 30 seconds, not pushed.
- **`put`, `mv` and `rm` have no conflict detection: the last write wins.** The spaces alpha has
  no compare-and-swap for writes. `atdrive sync` and the Mac app do make conflicted copies, but
  without compare-and-swap an edit made elsewhere in the second before a sync uploads can still be
  overwritten.
- **`atdrive sync` sends whole files,** even when only part of one changed. While a big one
  transfers, other changes wait.
- **`atdrive sync` on a Mac** works, but two names that differ only in case (`Notes.txt` and
  `notes.txt`) clash on Mac disks. The app doesn't have this problem.
- **No trash on the drive.** Deleting in Finder or in a synced folder deletes from the drive.
- **One passkey per drive.** Adding a second passkey, or a recovery key to print and keep, comes
  later (see PLAN.md).
- **Symlinks and aliases aren't stored.**
- **Transfers are sequential.**
- **A single file is capped at about 30 GB,** because its chunk list has to fit in one 1 MiB
  record.

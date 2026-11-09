# ATDrive

A file drive that keeps your files in your own atproto account, privately, using
[atproto spaces](https://atproto.com/blog/atproto-spaces-alpha). On macOS the drive shows up in
Finder like iCloud Drive or Dropbox: files download when you open them and upload when you save.
On macOS and Linux there's also a command-line tool.

> **Alpha. Don't store anything sensitive or irreplaceable.**
> - Spaces are an alpha protocol, and Bluesky's hosted alpha PDS may be wiped without warning.
> - Spaces control *who can access* data, but they **don't encrypt it**. Whoever runs your PDS
>   can read your files.

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
2. **ATDrive** appears in Finder's sidebar under Locations.
3. Drag files in, open them, rename them, delete them. Changes made elsewhere (another Mac, the
   CLI) show up within about 30 seconds.

Files are downloaded the first time you open them. Right-click > Remove Download frees the space
again. If you edit a file on two devices at once, neither edit is lost: the second one to sync is
saved as `name (conflicted copy <date>).ext`.

`scripts/build-app.sh` builds the app without installing it. The top of the script lists its
signing options.

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

Paths in the drive always start from the top (`/photos/cat.jpg`).

**Signing in.** ATDrive uses atproto OAuth: you sign in on your own PDS's page in the browser,
and ATDrive never sees your password.
- **What it gets:** tokens that are tied to a key only it holds, saved in
  `~/.config/atdrive/session.json` (mode 600) for the CLI, or in the app's container on the Mac.
- **What it asks for:**
  - writes only to ATDrive's own records;
  - creating its space;
  - uploading file contents;
  - read access to the private spaces you own. This is broader than ATDrive needs, until
    its schema is published (see PLAN.md).
- **Sessions last two weeks.** That's the limit Bluesky's servers set for apps without a
  backend. After that, sign in again.

On machines without a browser, `atdrive login --app-password <handle>` signs in with an
app password from your account settings instead.

## How it works

- **Your drive is one space:** `at://<your-did>/space/me.jsnelgro.atdrive.drive/default`. It uses
  the `personalspace` policy, so only your account can read or write it.
- **Each file or folder is one record** (`me.jsnelgro.atdrive.node`, see [`lexicons/`](lexicons)).
  A record names its parent folder by ID rather than storing a path, so a rename or move is one
  small update, however much a folder contains.
- **File contents are stored as blobs** in 4 MiB chunks. Each chunk is checked against its content
  ID (CID), and each downloaded file is checked against its SHA-256.
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
  itself.

Mac app logs (app and extension):

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "me.jsnelgro.atdrive"'
```

See [PLAN.md](PLAN.md) for the roadmap and design notes.

## Current limitations

- **One drive per account.** The Mac app and the CLI each keep their own login.
- **Remote changes are polled** every 30 seconds, not pushed.
- **The CLI has no conflict detection: the last write wins.** The spaces alpha has no
  compare-and-swap for writes. The Mac app does make conflicted copies.
- **No trash on the drive.** Deleting in Finder deletes from the drive.
- **Symlinks and aliases aren't stored.**
- **Transfers are sequential.**
- **A single file is capped at about 30 GB,** because its chunk list has to fit in one 1 MiB
  record.

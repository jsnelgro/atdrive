# ATDrive

A file drive that keeps your files in your own atproto account, privately, using
[atproto spaces](https://atproto.com/blog/atproto-spaces-alpha). Today it's a command-line tool for
macOS and Linux. Finder and Files app integration (Apple's File Provider) comes next.

> **Alpha. Don't store anything sensitive or irreplaceable.**
> - Spaces are an alpha protocol, and Bluesky's hosted alpha PDS may be wiped without warning.
> - Spaces control *who can access* data, but they **don't encrypt it**. Whoever runs your PDS
>   can read your files.

## Install

Requires a Swift 6 toolchain: Xcode or the Command Line Tools on macOS,
[swift.org](https://www.swift.org/install/) on Linux.

```bash
scripts/build.sh
```

```bash
cp build/atdrive ~/.local/bin/
```

## Use

```bash
atdrive login alice.example.com     # prompts for an app password
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

**Passwords.** Log in with an *app password* if your account has one, since it can be revoked
without changing your real password. Your main password works too. The password is used once
and never stored. ATDrive keeps only the session tokens, in `~/.config/atdrive/session.json`
(mode 600).

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

The end-to-end test runs against a real spaces PDS and cleans up after itself:

```bash
ATDRIVE_LIVE_HANDLE=you.spaces-alpha.bsky.network ATDRIVE_LIVE_PASSWORD=xxxx-xxxx-xxxx-xxxx scripts/test.sh --filter LiveTests
```

See [PLAN.md](PLAN.md) for the roadmap and design notes.

## Current limitations

- **One drive per account, and commands are one-shot.** There's no background sync or folder
  watching yet.
- **No conflict detection: the last write wins.** The spaces alpha has no compare-and-swap for
  writes. Conflict copies come with the sync engine.
- **Transfers are sequential.**
- **A single file is capped at about 30 GB,** because its chunk list has to fit in one 1 MiB
  record.

> **Alpha.** Don't store anything irreplaceable in ATDrive yet. See the [README](https://github.com/__REPO__#readme).

## Installing

**Mac (the app, with Finder):** download `ATDrive-__VERSION__-macos-arm64.zip` (Apple silicon, macOS 14 or later), unzip it and move **ATDrive** to Applications. It isn't notarized by Apple, so macOS blocks it the first time. In Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/ATDrive.app
```

Or open it once, then go to System Settings › Privacy & Security and click **Open Anyway**. The app's menu has **Install Command-Line Tool…** for the `atdrive` command too. (If the Mac files aren't attached yet, they're on their way: they're added by hand after the Linux build.)

**Linux:** download the file for your machine (`uname -m` says which: `x86_64` or `aarch64`). It runs on any distribution.

```bash
tar -xzf atdrive-__VERSION__-linux-x86_64.tar.gz
mkdir -p ~/.local/bin && mv atdrive ~/.local/bin/
atdrive login alice.example.com
```

**Mac (the command line only):** `atdrive-__VERSION__-macos-arm64.tar.gz`. Unpack it as above. If macOS says it can't check it for malware: `xattr -d com.apple.quarantine ~/.local/bin/atdrive`.

**Checking a download:** every file has its checksum next to it (`<file>.sha256`). `shasum -a 256 -c <file>.sha256` (`sha256sum -c` on Linux) says OK if they match. The Linux files also have a build attestation: `gh attestation verify <file> -R __REPO__`.

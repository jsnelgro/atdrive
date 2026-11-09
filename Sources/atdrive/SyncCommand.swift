import ATDriveCore
import ArgumentParser
import Foundation

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep a folder on this computer in sync with the drive.",
        discussion: """
            Changes go both ways as they happen. Edit, add, move or delete files in the folder and the drive follows within seconds. Changes made elsewhere (the Mac app, other computers, other atdrive commands) show up in the folder within --interval seconds.

              atdrive sync                  sync ~/atdrive until stopped
              atdrive sync ~/Drive --once   sync once, then exit
              atdrive sync --install        keep ~/atdrive in sync in the
                                            background (Linux, systemd)

            A folder that already has files in it is merged with the drive: matching files and folders are paired up, and nothing is deleted. A file edited in both places keeps the drive's version under its name, and yours is saved next to it as "name (conflicted copy <date>)".
            """
    )

    @Argument(help: "The folder to sync (default: ~/atdrive).")
    var folder: String?

    @Flag(help: "Sync once, then exit.")
    var once = false

    @Option(help: "Seconds between checks for changes on the drive.")
    var interval = 30

    @Flag(help: "Linux: sync in the background from now on, as a systemd user service.")
    var install = false

    @Flag(help: "Linux: stop syncing in the background and remove the service.")
    var uninstall = false

    /// Exit status for problems retrying won't fix (the service doesn't restart on it).
    static let fatalStatus: Int32 = 78

    func validate() throws {
        if interval < 5 { throw ValidationError("--interval must be at least 5 seconds") }
        if install && uninstall { throw ValidationError("choose --install or --uninstall") }
        if once && (install || uninstall) { throw ValidationError("--once can't be combined with --install") }
    }

    func run() async throws {
        let url = URL(fileURLWithPath: NSString(string: folder ?? "~/atdrive").expandingTildeInPath)
        if install { return try Service.install(folder: url, interval: interval) }
        if uninstall { return try Service.uninstall() }

        // As a service (no terminal), wait to be signed in rather than fail.
        let waits = !once && isatty(STDIN_FILENO) == 0
        var context = waits ? try await Self.waitForSignIn() : try await Context.load()
        let sync: FolderSync
        do {
            sync = try FolderSync(folder: url, drive: context.drive) { SyncLog.write($0.description) }
        } catch let error as SyncError {
            throw Self.fatal(error)
        }
        let handle = await context.session.session.handle
        SyncLog.write("Syncing \(sync.root) with @\(handle)'s drive\(once ? "" : " (Ctrl-C to stop)").")

        if once {
            var result = try await sync.sync()
            for _ in 0..<30 where result.waiting {
                try await Task.sleep(for: .seconds(2))
                result = try await sync.sync(checkRemote: false)
            }
            SyncLog.write(result.waiting ? "Some files are still being written; they'll sync next time." : "✓ In sync.")
            return
        }

        let watcher = FolderWatcher()
        let clock = ContinuousClock()
        var nextDriveCheck = clock.now
        var failures = 0
        var announced = false
        while true {
            let mark = watcher.mark()
            do {
                let result = try await sync.sync(checkRemote: clock.now >= nextDriveCheck)
                if result.checkedRemote { nextDriveCheck = clock.now + .seconds(interval) }
                watcher.watch(result.folders)
                if !announced || failures > 0 {
                    SyncLog.write(
                        "✓ In sync. "
                            + (watcher.isWatching
                                ? "Watching for changes; the drive is checked every \(interval)s."
                                : "Checking the folder every 5s and the drive every \(interval)s."))
                    announced = true
                    failures = 0
                }
                var timeout = nextDriveCheck - clock.now
                if result.waiting { timeout = min(timeout, .seconds(1)) }  // files still being written
                if !watcher.isWatching { timeout = min(timeout, .seconds(5)) }
                await watcher.wait(since: mark, timeout: max(timeout, .milliseconds(100)))
            } catch let error as SyncError {
                throw Self.fatal(error)
            } catch let error as ATDriveError where error == .sessionEnded || error == .notLoggedIn {
                let expired = await context.session.session
                SyncLog.write("Your session has ended. Run `atdrive login <handle>` to resume syncing.")
                context = try await Self.waitForSignIn(after: expired)
                do { try sync.use(context.drive) } catch let error as SyncError { throw Self.fatal(error) }
                SyncLog.write("Signed in again; resuming.")
            } catch {
                failures += 1
                let delay = min(15 << min(failures - 1, 5), 300)
                SyncLog.write("error: \(error) (trying again in \(delay)s)", toStandardError: true)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private static func fatal(_ error: SyncError) -> ExitCode {
        SyncLog.write("Error: \(error)", toStandardError: true)
        return ExitCode(fatalStatus)
    }

    /// Waits until a session other than `expired` is saved (by `atdrive login`), then loads it.
    private static func waitForSignIn(after expired: Session? = nil) async throws -> Context {
        var said = expired != nil
        while true {
            if let saved = try? SessionStore().load(), saved != expired { return try await Context.load() }
            if !said {
                SyncLog.write("Not signed in. Run `atdrive login <handle>`; syncing starts once you have.")
                said = true
            }
            try await Task.sleep(for: .seconds(5))
        }
    }
}

/// Unbuffered (unlike `print` when not on a terminal), so lines reach journald right away.
enum SyncLog {
    private static let timestamps = isatty(STDOUT_FILENO) != 0  // journald adds its own

    static func write(_ line: String, toStandardError: Bool = false) {
        var text = line
        if timestamps {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            text = "\(formatter.string(from: Date())) \(line)"
        }
        (toStandardError ? FileHandle.standardError : FileHandle.standardOutput).write(Data((text + "\n").utf8))
    }
}

/// `atdrive sync` as a systemd user service, so the folder stays in sync after the terminal
/// closes and after a reboot.
enum Service {
    static let name = "atdrive-sync.service"

    static func install(folder: URL, interval: Int) throws {
        #if os(Linux)
            guard let session = try SessionStore().load() else { throw ATDriveError.notLoggedIn }
            let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().path
            var command = [executable, "sync", folder.standardizedFileURL.path]
            if interval != 30 { command += ["--interval", String(interval)] }
            let unit = """
                [Unit]
                Description=ATDrive: keep \(escape(folder.path)) in sync with @\(session.handle)'s drive

                [Service]
                ExecStart=\(command.map { quote($0, forCommand: true) }.joined(separator: " "))
                Environment=\(quote("ATDRIVE_CONFIG_DIR=\(SessionStore().directory.path)", forCommand: false))
                Restart=on-failure
                RestartSec=30
                RestartPreventExitStatus=\(Sync.fatalStatus)

                [Install]
                WantedBy=default.target

                """
            let file = unitFile
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(unit.utf8).write(to: file)
            print("Wrote \(file.path)")
            if executable.contains("/.build/") {
                print("note: it runs \(executable); copy atdrive somewhere permanent and run --install from there")
            }

            guard systemctl("daemon-reload"), systemctl("enable", name), systemctl("restart", name) else {
                print(
                    """

                    Couldn't start it with systemctl (is systemd running for your user?). To start it by hand:
                      systemctl --user daemon-reload && systemctl --user enable --now \(name)
                    """)
                throw ExitCode.failure
            }
            print("Syncing \(folder.path) in the background, now and whenever you're logged in.")
            if run("loginctl", "show-user", String(getuid()), "--property=Linger", "--value").output == "no" {
                print(
                    """

                    To keep syncing after you log out (e.g. on a server you SSH into), run:
                      loginctl enable-linger
                    """)
            }
            print(
                """

                  journalctl --user -u \(name) -f        follow what it's doing
                  systemctl --user status \(name)        is it running?
                  atdrive sync --uninstall                     stop and remove it
                """)
        #else
            throw ValidationError("--install is for Linux (systemd). On a Mac, use the ATDrive app.")
        #endif
    }

    static func uninstall() throws {
        #if os(Linux)
            let stopped = systemctl("disable", "--now", name)
            if FileManager.default.fileExists(atPath: unitFile.path) {
                try FileManager.default.removeItem(at: unitFile)
                print("Removed \(unitFile.path)")
            }
            guard stopped else {
                print("Couldn't reach systemd to stop it. If it's running: systemctl --user disable --now \(name)")
                throw ExitCode.failure
            }
            _ = systemctl("daemon-reload")
            print("Stopped syncing in the background. The folder and the drive are left as they are.")
        #else
            throw ValidationError("--uninstall is for Linux (systemd).")
        #endif
    }

    private static var unitFile: URL {
        let environment = ProcessInfo.processInfo.environment
        let config =
            environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("systemd/user/\(name)")
    }

    /// `%` starts a specifier anywhere in a unit file.
    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "%", with: "%%") }

    /// Quotes a word for a unit file; in commands, `$` also expands variables.
    private static func quote(_ word: String, forCommand: Bool) -> String {
        var escaped = escape(
            word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))
        if forCommand { escaped = escaped.replacingOccurrences(of: "$", with: "$$") }
        return "\"\(escaped)\""
    }

    private static func systemctl(_ arguments: String...) -> Bool {
        let result = run("systemctl", ["--user"] + arguments)
        if result.status != 0, !result.error.isEmpty {
            FileHandle.standardError.write(Data((result.error + "\n").utf8))
        }
        return result.status == 0
    }

    private static func run(_ tool: String, _ arguments: String...) -> (status: Int32, output: String, error: String) {
        run(tool, arguments)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return (127, "", "\(error)") }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        func text(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (process.terminationStatus, text(out), text(err))
    }
}

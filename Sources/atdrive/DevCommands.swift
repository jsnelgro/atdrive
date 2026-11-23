import ATDriveCore
import ArgumentParser
import Foundation

/// For developing and testing ATDrive, not for everyday use.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "For developing and testing ATDrive.",
        subcommands: [Reset.self, ListIgnored.self, DeleteIgnored.self, DiskUsage.self, Lexicons.self])
}

struct ListIgnored: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-ignored",
        abstract: "List what's ignored, in your synced folder and in the drive.",
        discussion: IgnoredCommand.explanation)

    @Option(help: IgnoredCommand.folderHelp)
    var folder: String?

    func run() async throws {
        let (_, found) = try await IgnoredCommand.find(folder: folder)
        IgnoredCommand.list(found, deleting: false)
    }
}

struct DeleteIgnored: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-ignored",
        abstract: "Delete what's ignored, in your synced folder and in the drive.",
        discussion: IgnoredCommand.explanation + "\n\n" + """
            It lists it all first (as `atdrive dev list-ignored` does), and asks. What's in the drive goes to the drive's trash (`atdrive restore` brings it back). What's in the synced folder was never in the drive, so it goes to this computer's trash instead (on Linux, the desktop's: ~/.local/share/Trash, which file managers and `gio trash` show).
            """)

    @Option(help: IgnoredCommand.folderHelp)
    var folder: String?

    @Flag(name: .shortAndLong, help: "Don't ask: delete straight away.")
    var yes = false

    func run() async throws {
        let (drive, found) = try await IgnoredCommand.find(folder: folder)
        guard IgnoredCommand.list(found, deleting: true) else { return }
        if !yes {
            guard try Output.confirm("Delete \(found.count) things?") else {
                print("Nothing deleted.")
                return
            }
        }
        try await IgnoredFiles.delete(found, in: drive) { deletion in
            let name = "\(deletion.path)\(deletion.isFolder ? "/" : "")"
            if let problem = deletion.problem {
                Output.warn("couldn't move \(name) to the trash, so it's still there: \(problem)")
            } else {
                print("✗ \(name)\(deletion.count > 1 ? "  (\(deletion.count) items)" : "")")
            }
        }
    }
}

/// What `dev list-ignored` and `dev delete-ignored` share: the finding is in the core
/// (`IgnoredFiles`); this is the printing.
enum IgnoredCommand {
    static let explanation = """
        What's ignored: what .atdriveignore files ignore, what .gitignore files ignore (unless ignore.respect_gitignore = false), and ignore.patterns in config.toml.
        - In the synced folder, by the ignore files there, as `atdrive sync` sees them.
        - In the drive, by the ignore files in it: things that got in before they were ignored, or from somewhere that doesn't ignore them. Your own files only: not shares, or the Spaces folder.
        A synced folder's own .atdrive folder never counts.

        The synced folder is the one `atdrive sync --install` set up, or else ~/atdrive (--folder names another). Either way, it has to be one `atdrive sync` keeps in sync with this drive: any other folder is refused.
        """
    static let folderHelp: ArgumentHelp =
        "The synced folder (default: the one `atdrive sync --install` set up, or ~/atdrive)."

    static func find(folder named: String?) async throws -> (JoinedDrive, IgnoredFiles.Found) {
        let settings = try ConfigFile.standard().load().ignore
        let context = try await Context.load()
        func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }
        let folder = try IgnoredFiles.folder(
            named: named.map(expand), installed: Service.installedFolder, standard: expand("~/atdrive"),
            drive: context.drive)
        switch folder {
        case .named(let path), .standard(let path): print("Synced folder: \(path)")
        case .installed(let path): print("Synced folder: \(path) (set up by `atdrive sync --install`)")
        case .none(let installed?):
            Output.warn(
                "\(installed), which `atdrive sync --install` set up, isn't synced with this drive: only looking in the drive"
            )
        case .none(nil):
            print(
                "No synced folder (none set up by `atdrive sync --install`, and ~/atdrive isn't one): only the drive.")
        }
        return (context.joined, try await IgnoredFiles.find(in: context.joined, folder: folder, settings: settings))
    }

    /// Prints it all; whether there's anything.
    @discardableResult
    static func list(_ found: IgnoredFiles.Found, deleting: Bool) -> Bool {
        if found.isEmpty {
            print("Nothing is ignored.")
            return false
        }
        if let root = found.folder.path, !found.local.isEmpty {
            print("In \(root)\(deleting ? ", to this computer's trash" : ""):")
            for item in found.local { print("  \(item.path)\(item.isFolder ? "/" : "")") }
        }
        if !found.remote.isEmpty {
            print("In the drive\(deleting ? ", to the drive's trash" : ""):")
            for node in found.remote { print("  \(found.tree.path(of: node))\(node.isFolder ? "/" : "")") }
        }
        return true
    }
}

struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete everything, as if ATDrive had never been used on your account.",
        discussion: """
            For trying things out and testing: takes your account back to a clean slate. It deletes:
            - your drive, with everything in it and all its history;
            - everything you shared (people you shared it with lose it too);
            - your published sharing key, and this device's identity.
            Things other people shared with you aren't touched; they're no longer in your drive.

            Afterwards your account has no drive. The next sign-in (`atdrive login`, or the Mac
            app) makes one, and asks whether to encrypt it. Your other devices have to sign in
            again, and a synced folder of the old drive stops syncing (its files stay where they
            are).
            """)

    @Flag(name: .shortAndLong, help: "Don't ask: delete straight away.")
    var yes = false

    func run() async throws {
        let context = try await Context.locked()
        let session = await context.session.session
        if !yes {
            print(
                "This deletes everything in @\(session.handle)'s drive, and every folder it shared. It can't be undone."
            )
            guard Prompt.isInteractive else {
                throw ValidationError("not on a terminal to confirm: pass --yes")
            }
            let typed = Prompt.line("Type your handle (\(session.handle)) to confirm: ")?
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard typed?.lowercased() == session.handle.lowercased() else {
                print("Nothing deleted.")
                return
            }
        }
        let result = try await AccountReset.run(client: context.drive.client, owner: session.did)
        try context.store.devices.delete()
        let shared = result.spaces.filter { $0 != context.drive.space }.count
        print("✓ Deleted your drive\(shared > 0 ? " and \(shared) share\(shared == 1 ? "" : "s")" : "").")
        print("Your account has no drive now. Signing in (`atdrive login`, or the Mac app) makes one.")
    }
}

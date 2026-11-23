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
        discussion: IgnoredThings.explanation)

    @Option(help: "The synced folder (default: ~/atdrive).")
    var folder: String?

    func run() async throws {
        let found = try await IgnoredThings.find(folder: folder)
        found.list(deleting: false)
    }
}

struct DeleteIgnored: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-ignored",
        abstract: "Delete what's ignored, in your synced folder and in the drive.",
        discussion: IgnoredThings.explanation + "\n\n" + """
            It lists it all first (as `atdrive dev list-ignored` does), and asks. What's in the synced folder is deleted for good: it was never in the drive, so there's no other copy. What's in the drive goes to the trash (`atdrive restore` brings it back).
            """)

    @Option(help: "The synced folder (default: ~/atdrive).")
    var folder: String?

    @Flag(name: .shortAndLong, help: "Don't ask: delete straight away.")
    var yes = false

    func run() async throws {
        let found = try await IgnoredThings.find(folder: folder)
        guard found.list(deleting: true) else { return }
        if !yes {
            guard try Output.confirm("Delete \(found.count) things?") else {
                print("Nothing deleted.")
                return
            }
        }
        if let root = found.root {
            for item in found.local {
                do {
                    try FileManager.default.removeItem(atPath: "\(root)/\(item.path)")
                    print("✗ \(item.path)\(item.isFolder ? "/" : "")")
                } catch {
                    Output.warn("couldn't delete \(item.path): \(error.localizedDescription)")
                }
            }
        }
        for node in found.remote {
            let nodes = node.isFolder ? found.tree.descendants(of: node.id) + [node] : [node]
            try await found.drive.delete(nodes)
            print(
                "✗ \(found.tree.path(of: node))\(node.isFolder ? "/" : "")\(nodes.count > 1 ? "  (\(nodes.count) items)" : "")"
            )
        }
    }
}

/// What's ignored, in the synced folder and in the drive: what `dev list-ignored` lists and
/// `dev delete-ignored` deletes. The outermost things only: an ignored folder goes with
/// everything in it.
struct IgnoredThings {
    static let explanation = """
        What's ignored: what .atdriveignore files ignore, what .gitignore files ignore (unless ignore.respect_gitignore = false), and ignore.patterns in config.toml.
        - In the synced folder, by the ignore files there, as `atdrive sync` sees them.
        - In the drive, by the ignore files in it: things that got in before they were ignored, or from somewhere that doesn't ignore them. Your own files only: not shares, or the Spaces folder.
        A synced folder's own .atdrive folder never counts.
        """

    /// The synced folder, if there is one.
    var root: String?
    var local: [(path: String, isFolder: Bool)] = []
    let drive: JoinedDrive
    let tree: DriveTree
    var remote: [Node] = []

    var count: Int { local.count + remote.count }

    static func find(folder: String?) async throws -> IgnoredThings {
        let settings = try ConfigFile.standard().load().ignore
        let drive = try await Context.load().joined
        let tree = try await drive.update(nil).tree
        var found = IgnoredThings(drive: drive, tree: tree)

        let path = NSString(string: folder ?? "~/atdrive").expandingTildeInPath
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
            found.root = path
            found.local = try IgnoredFiles.local(in: path, settings: settings)
        } else if folder != nil {
            throw ATDriveError.notAFolder(path)
        } else {
            Output.warn("no synced folder at \(path), so only the drive (--folder names another)")
        }

        found.remote = try await IgnoredFiles.inDrive(tree, settings: settings) { node in
            var data = Data()
            try await drive.read(node) { data += $0 }
            return String(decoding: data, as: UTF8.self)
        }
        return found
    }

    /// Prints it all; whether there's anything.
    @discardableResult
    func list(deleting: Bool) -> Bool {
        if local.isEmpty, remote.isEmpty {
            print("Nothing is ignored.")
            return false
        }
        if let root, !local.isEmpty {
            print("In \(root)\(deleting ? ", deleted for good" : ""):")
            for item in local { print("  \(item.path)\(item.isFolder ? "/" : "")") }
        }
        if !remote.isEmpty {
            print("In the drive\(deleting ? ", to the trash" : ""):")
            for node in remote { print("  \(tree.path(of: node))\(node.isFolder ? "/" : "")") }
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

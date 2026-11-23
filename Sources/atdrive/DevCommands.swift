import ATDriveCore
import ArgumentParser
import Foundation

/// For developing and testing ATDrive, not for everyday use.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "For developing and testing ATDrive.",
        subcommands: [Reset.self, DeleteIgnored.self, DiskUsage.self, Lexicons.self])
}

struct DeleteIgnored: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-ignored",
        abstract: "Delete what's ignored, in your synced folder and in the drive.",
        discussion: """
            What's ignored: what .atdriveignore and .gitignore files ignore (the latter unless ignore.respect_gitignore = false), and ignore.patterns in config.toml. It lists everything first, and asks.
            - In the synced folder (~/atdrive, or --folder), by the ignore files there, as `atdrive sync` sees them. These are deleted for good: they were never in the drive, so there's no other copy and no trash.
            - In the drive, by the ignore files in it: what got in before it was ignored, or from somewhere that doesn't ignore it. These go to the trash (`atdrive restore` brings one back). Your own files only: not shares, or the Spaces folder.
            An ignored folder goes with everything in it. A synced folder's own .atdrive folder is never touched.
            """)

    @Option(help: "The local folder (default: ~/atdrive).")
    var folder: String?

    @Flag(help: "Only in the local folder.")
    var localOnly = false

    @Flag(help: "Only in the drive.")
    var driveOnly = false

    @Flag(help: "List what would be deleted, and delete nothing.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Don't ask: delete straight away.")
    var yes = false

    func validate() throws {
        if localOnly, driveOnly { throw ValidationError("--local-only and --drive-only: pick one") }
    }

    func run() async throws {
        let settings = try ConfigFile.standard().load().ignore

        // Here.
        var root: String?
        var local: [(path: String, isFolder: Bool)] = []
        if !driveOnly {
            let path = NSString(string: folder ?? "~/atdrive").expandingTildeInPath
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                root = path
                local = try IgnoredFiles.local(in: path, settings: settings)
            } else if folder != nil {
                throw ATDriveError.notAFolder(path)
            } else {
                Output.warn("no folder at \(path): skipping it (--folder names another)")
            }
        }

        // In the drive.
        var context: Context?
        var tree: DriveTree?
        var remote: [Node] = []
        if !localOnly {
            let loaded = try await Context.load()
            let drive = loaded.joined
            let snapshot = try await drive.update(nil)
            remote = try await IgnoredFiles.inDrive(snapshot.tree, settings: settings) { node in
                var data = Data()
                try await drive.read(node) { data += $0 }
                return String(decoding: data, as: UTF8.self)
            }
            context = loaded
            tree = snapshot.tree
        }

        if local.isEmpty, remote.isEmpty {
            print("Nothing is ignored\(localOnly ? " here" : driveOnly ? " in the drive" : "").")
            return
        }
        if let root, !local.isEmpty {
            print("In \(root), deleted for good:")
            for item in local { print("  \(item.path)\(item.isFolder ? "/" : "")") }
        }
        if let tree, !remote.isEmpty {
            print("In the drive, to the trash:")
            for node in remote { print("  \(tree.path(of: node))\(node.isFolder ? "/" : "")") }
        }
        if dryRun {
            print("Nothing deleted (--dry-run).")
            return
        }
        if !yes {
            guard try Output.confirm("Delete \(local.count + remote.count) things?") else {
                print("Nothing deleted.")
                return
            }
        }

        if let root {
            for item in local {
                do {
                    try FileManager.default.removeItem(atPath: "\(root)/\(item.path)")
                    print("✗ \(item.path)\(item.isFolder ? "/" : "")")
                } catch {
                    Output.warn("couldn't delete \(item.path): \(error.localizedDescription)")
                }
            }
        }
        if let context, let tree {
            for node in remote {
                let nodes = node.isFolder ? tree.descendants(of: node.id) + [node] : [node]
                try await context.joined.delete(nodes)
                print(
                    "✗ \(tree.path(of: node))\(node.isFolder ? "/" : "")\(nodes.count > 1 ? "  (\(nodes.count) items)" : "")"
                )
            }
        }
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

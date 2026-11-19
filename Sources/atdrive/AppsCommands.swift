import ATDriveCore
import ArgumentParser
import Foundation

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Data from your other apps' spaces, and spaces shared with you: read-only.",
        discussion: """
            Other atproto apps keep data in spaces too (a Bulletin board's notes, say), and people share spaces with you. This shows all of it, read-only, as folders:

              <owner>/<space type> – <space key>/<writer>/<collection>/<record key>.json

            Records are JSON as stored; the files a record references are beside it, in <record key>.blobs/. Your ATDrive files aren't here: they're the drive.

            It's off until you turn it on (`atdrive apps on`, or apps.enabled in config.toml): it downloads other people's data. A space shared with you that you've never written to has to be added by its address (`atdrive apps add`), once, for all your devices.

            Nothing here changes another app's data. `atdrive apps export` makes a copy in a folder, which you can do anything with.
            """,
        subcommands: [On.self, Off.self, List.self, Tree.self, Cat.self, Add.self, Remove.self, Export.self]
    )

    /// The apps view for the logged-in account; it must be turned on.
    static func load() async throws -> AppData {
        guard try ConfigFile.standard().load().appsEnabled else { throw AppDataError.off }
        let context = try await Context.load()
        return AppData(
            home: context.drive, access: SpaceAccess(ownClient: context.drive.client, resolver: IdentityResolver()))
    }

    /// The apps view now, as files.
    static func tree() async throws -> (AppData, AppTree) {
        let apps = try await load()
        Output.status("Reading your spaces…")
        let snapshot = try await apps.update()
        Output.clearStatus()
        return (apps, snapshot.tree)
    }

    struct On: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn the apps view on (apps.enabled in config.toml).")

        func run() async throws {
            try ConfigFile.standard().update { $0.appsEnabled = true }
            print("✓ The apps view is on: `atdrive apps ls`. On a Mac, ATDrive Apps shows up in Finder.")
            if OAuthLogin.appsNeedNewSignIn {
                print("It needs access to all your spaces: sign in again (`atdrive login <handle>`) to grant it.")
            }
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn the apps view off. What you exported stays where it is.")

        func run() async throws {
            try ConfigFile.standard().update { $0.appsEnabled = false }
            print("✓ The apps view is off.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List a folder in the apps view.")

        @Argument(help: "Folder (default: the top).")
        var path = "/"

        @Flag(name: .short, help: "Show sizes.")
        var long = false

        func run() async throws {
            let (_, tree) = try await Apps.tree()
            let path = DrivePath(path)
            let start = try tree.locate(path)
            let items = start.map { $0.isFolder ? tree.children(of: $0.id) : [$0] } ?? tree.children(of: nil)
            if items.isEmpty, start == nil {
                print(
                    "Nothing yet: none of your spaces are other apps'. Add one shared with you with `atdrive apps add`."
                )
            }
            for item in items {
                let name = item.isFolder ? item.name + "/" : item.name
                if long {
                    let size = item.size.map(Output.size) ?? ""
                    print("\(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(name)")
                } else {
                    print(name)
                }
            }
        }
    }

    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a folder in the apps view and everything in it.")

        @Argument(help: "Folder (default: the top).")
        var path = "/"

        func run() async throws {
            let (_, tree) = try await Apps.tree()
            let path = DrivePath(path)
            let start = try tree.locate(path)
            if let start, !start.isFolder { throw ATDriveError.notAFolder(path.description) }
            var files = 0
            func walk(_ folder: String?, prefix: String) {
                let children = tree.children(of: folder)
                for (index, item) in children.enumerated() {
                    let last = index == children.count - 1
                    if item.isFolder {
                        print("\(prefix)\(last ? "└── " : "├── ")\(item.name)/")
                        walk(item.id, prefix: prefix + (last ? "    " : "│   "))
                    } else {
                        files += 1
                        let size = item.size.map { "  (\(Output.size($0)))" } ?? ""
                        print("\(prefix)\(last ? "└── " : "├── ")\(item.name)\(size)")
                    }
                }
            }
            print(path.description)
            walk(start?.id, prefix: "")
            print("\n\(files) file\(files == 1 ? "" : "s")")
        }
    }

    struct Cat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a file from the apps view: a record's JSON, or a file it references.")

        @Argument(help: "File in the apps view.")
        var path: String

        func run() async throws {
            let (apps, tree) = try await Apps.tree()
            guard let item = try tree.locate(DrivePath(path)) else { throw ATDriveError.isAFolder("/") }
            FileHandle.standardOutput.write(try await apps.contents(of: item))
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a space shared with you, by its address, for all your devices.",
            discussion: """
                Spaces you own or have written to show up by themselves. One shared with you that you've never written to doesn't (atproto has no way to list those), so add it by its address:

                  atdrive apps add at://alice.example.com/space/my.bulletin.board/home
                """)

        @Argument(help: "The space's address: at://<handle or DID>/space/<type>/<key>.")
        var address: String

        func run() async throws {
            let apps = try await Apps.load()
            let space = try await apps.add(address)
            print("✓ Added \(space). It's in `atdrive apps ls` on all your devices.")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Take a space you added out of the apps view, on all your devices.")

        @Argument(help: "The space's address.")
        var address: String

        func run() async throws {
            let apps = try await Apps.load()
            try await apps.remove(address)
            print("✓ Removed it. Nothing in the space changed.")
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy the apps view into a folder on this computer.",
            discussion: """
                A one-way copy: run it again to bring the folder up to date (only what changed is written). Changes made in the folder stay there, and never go back to the apps.
                """)

        @Argument(help: "Folder to copy into (made if needed).")
        var folder: String

        @Option(help: "Only this folder of the apps view.")
        var path = "/"

        @Flag(help: "Delete files in the folder that aren't in the apps view (any more).")
        var delete = false

        func run() async throws {
            let (apps, tree) = try await Apps.tree()
            let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            let base = DrivePath(path)
            let start = try tree.locate(base)
            if let start, !start.isFolder { throw ATDriveError.notAFolder(base.description) }
            let items = tree.descendants(of: start?.id).sorted {
                tree.path(of: $0.id).components.count < tree.path(of: $1.id).components.count
            }
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            var expected: Set<String> = []
            var written = 0
            var files = 0
            for item in items {
                let relative = tree.path(of: item.id).components.dropFirst(base.components.count)
                    .joined(separator: "/")
                expected.insert(relative)
                let url = root.appendingPathComponent(relative)
                if item.isFolder {
                    try manager.createDirectory(at: url, withIntermediateDirectories: true)
                    continue
                }
                files += 1
                if case .blob = item.content, let size = item.size,
                    (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) == size
                {
                    continue  // named by its CID: the same name is the same contents
                }
                Output.status("Copying \(relative)…")
                let data = try await apps.contents(of: item)
                if (try? Data(contentsOf: url)) == data { continue }
                try data.write(to: url, options: .atomic)
                written += 1
            }
            Output.clearStatus()
            var removed = 0
            if delete, let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) {
                var stale: [URL] = []
                let prefix = root.standardizedFileURL.path + "/"
                for case let url as URL in walker {
                    let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                    if !expected.contains(relative) {
                        stale.append(url)
                        walker.skipDescendants()
                    }
                }
                for url in stale {
                    try manager.removeItem(at: url)
                    removed += 1
                }
            }
            print(
                "✓ \(files) file\(files == 1 ? "" : "s") in \(root.path): \(written) new or changed"
                    + (delete ? ", \(removed) removed" : ""))
        }
    }
}

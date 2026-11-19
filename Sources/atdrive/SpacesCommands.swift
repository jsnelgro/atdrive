import ATDriveCore
import ArgumentParser
import Foundation

struct Spaces: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What's in every space you're in: other apps' data, and spaces shared with you. Read-only.",
        discussion: """
            Other atproto apps keep data in spaces too (a Bulletin board's notes, say), and people share spaces with you. This shows all of it, read-only, by app, then space, then record type:

              Bulletin/home/note/3l2kabc.json                 yours, in your board
              Bulletin/home/note/@bob.test 3l2mxyz.json       someone else's, in it too
              Bulletin/@carol.test kitchen/note/…             a board someone else owns

            Records are JSON as stored; the files a record references are beside it, in <record>.blobs/. Your ATDrive files aren't here: they're the drive.

            It's off until you turn it on (`atdrive spaces on`, or spaces.enabled in config.toml): it downloads other people's data. Spaces you own or have written to show up by themselves; one shared with you that you've never written to has to be added by its address (`atdrive spaces add`), once, for all your devices.

            Nothing here changes another app's data. `atdrive spaces export` makes a copy in a folder, which you can do anything with.
            """,
        subcommands: [On.self, Off.self, List.self, Tree.self, Cat.self, Add.self, Remove.self, Export.self]
    )

    /// The spaces view for the logged-in account; it must be turned on.
    static func load() async throws -> SpaceData {
        guard try ConfigFile.standard().load().spacesEnabled else { throw SpaceDataError.off }
        let context = try await Context.load()
        return SpaceData(
            home: context.drive, access: SpaceAccess(ownClient: context.drive.client, resolver: IdentityResolver()))
    }

    /// The spaces view now, as files.
    static func tree() async throws -> (SpaceData, SpaceTree) {
        let spaces = try await load()
        Output.status("Reading your spaces…")
        let snapshot = try await spaces.update()
        Output.clearStatus()
        return (spaces, snapshot.tree)
    }

    /// An item's name as listed: folders end in `/`, and a space that can't all be read says why.
    static func listed(_ item: SpaceTree.Item) -> String {
        var name = item.isFolder ? item.name + "/" : item.name
        if let why = item.unreadable { name += "  (can't read: \(why))" }
        return name
    }

    struct On: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn the spaces view on (spaces.enabled in config.toml).")

        func run() async throws {
            try ConfigFile.standard().update { $0.spacesEnabled = true }
            print("✓ The spaces view is on: `atdrive spaces ls`. On a Mac, Spaces shows up in Finder.")
            if OAuthLogin.spacesNeedNewSignIn {
                print("It needs access to all your spaces: sign in again (`atdrive login <handle>`) to grant it.")
            }
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn the spaces view off. What you exported stays where it is.")

        func run() async throws {
            try ConfigFile.standard().update { $0.spacesEnabled = false }
            print("✓ The spaces view is off.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ls", abstract: "List a folder in the spaces view.")

        @Argument(help: "Folder (default: the top).")
        var path = "/"

        @Flag(name: .short, help: "Show sizes.")
        var long = false

        func run() async throws {
            let (_, tree) = try await Spaces.tree()
            let start = try tree.locate(DrivePath(path))
            if let why = start?.unreadable { print("(can't read all of it: \(why))") }
            let items = start.map { $0.isFolder ? tree.children(of: $0.id) : [$0] } ?? tree.children(of: nil)
            if items.isEmpty, start == nil {
                print(
                    "Nothing yet: you're in no spaces but ATDrive's. Add one shared with you with `atdrive spaces add`."
                )
            }
            for item in items {
                if long {
                    let size = item.size.map(Output.size) ?? ""
                    print("\(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(Spaces.listed(item))")
                } else {
                    print(Spaces.listed(item))
                }
            }
        }
    }

    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a folder in the spaces view and everything in it.")

        @Argument(help: "Folder (default: the top).")
        var path = "/"

        func run() async throws {
            let (_, tree) = try await Spaces.tree()
            let path = DrivePath(path)
            let start = try tree.locate(path)
            if let start, !start.isFolder { throw ATDriveError.notAFolder(path.description) }
            var files = 0
            func walk(_ folder: String?, prefix: String) {
                let children = tree.children(of: folder)
                for (index, item) in children.enumerated() {
                    let last = index == children.count - 1
                    if item.isFolder {
                        print("\(prefix)\(last ? "└── " : "├── ")\(Spaces.listed(item))")
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
            abstract: "Print a file from the spaces view: a record's JSON, or a file it references.")

        @Argument(help: "File in the spaces view.")
        var path: String

        func run() async throws {
            let (spaces, tree) = try await Spaces.tree()
            guard let item = try tree.locate(DrivePath(path)) else { throw ATDriveError.isAFolder("/") }
            let data = try await spaces.contents(of: item)
            FileHandle.standardOutput.write(data)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a space shared with you, by its address, for all your devices.",
            discussion: """
                Spaces you own or have written to show up by themselves. One shared with you that you've never written to doesn't (atproto has no way to list those), so add it by its address:

                  atdrive spaces add at://alice.example.com/space/my.bulletin.board/home
                """)

        @Argument(help: "The space's address: at://<handle or DID>/space/<type>/<key>.")
        var address: String

        func run() async throws {
            let spaces = try await Spaces.load()
            let space = try await spaces.add(address)
            print("✓ Added \(space). It's in `atdrive spaces ls` on all your devices.")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Take a space you added out of the spaces view, on all your devices.")

        @Argument(help: "The space's address.")
        var address: String

        func run() async throws {
            let spaces = try await Spaces.load()
            try await spaces.remove(address)
            print("✓ Removed it. Nothing in the space changed.")
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy the spaces view into a folder on this computer.",
            discussion: """
                A one-way copy: run it again to bring the folder up to date (only what changed is written). Changes made in the folder stay there, and never go back to the spaces.
                """)

        @Argument(help: "Folder to copy into (made if needed).")
        var folder: String

        @Option(help: "Only this folder of the spaces view.")
        var path = "/"

        @Flag(help: "Delete files in the folder that aren't in the spaces view (any more).")
        var delete = false

        func run() async throws {
            let (spaces, tree) = try await Spaces.tree()
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
                let data = try await spaces.contents(of: item)
                if (try? Data(contentsOf: url)) == data { continue }
                try data.write(to: url, options: .atomic)
                written += 1
            }
            Output.clearStatus()
            let removed = delete ? try Self.removeAllBut(expected, in: root) : 0
            print(
                "✓ \(files) file\(files == 1 ? "" : "s") in \(root.path): \(written) new or changed"
                    + (delete ? ", \(removed) removed" : ""))
        }

        /// Deletes what's in `root` but not at one of the `expected` paths (relative to it).
        /// Returns how many were deleted (a folder counts once).
        static func removeAllBut(_ expected: Set<String>, in root: URL) throws -> Int {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return 0
            }
            var stale: [URL] = []
            // Resolved on both sides: on a Mac, /tmp and /var are links to /private/….
            let prefix = root.resolvingSymlinksInPath().path + "/"
            while let url = walker.nextObject() as? URL {
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count))
                if !expected.contains(relative) {
                    stale.append(url)
                    walker.skipDescendants()
                }
            }
            for url in stale { try FileManager.default.removeItem(at: url) }
            return stale.count
        }
    }
}

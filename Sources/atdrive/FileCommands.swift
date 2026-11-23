import ATDriveCore
import ArgumentParser
import Foundation

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List a folder.")

    @Argument(help: "Folder (or file) in the drive.")
    var path = "/"

    @Flag(name: .shortAndLong, help: "Show size and modification time.")
    var long = false

    @Option(help: When.help("List it"), transform: When.parse)
    var at: Date?

    func run() async throws {
        let tree = try await Context.load().tree(at: at)
        let path = DrivePath(path)
        let entries: [Node]
        switch try tree.find(path) {
        case .missing: throw ATDriveError.notFound(path.description)
        case .root: entries = tree.children(of: nil)
        case .node(let node): entries = node.isFolder ? tree.children(of: node.id) : [node]
        }
        for node in entries {
            let name = node.isFolder ? node.name + "/" : node.name
            if long {
                let size = node.isFolder ? "-" : Output.size(node.record.size ?? 0)
                let date = Output.date(node.record.modifiedDate ?? node.record.createdDate)
                print("\(size.leftPadded(9))  \(date.leftPadded(16))  \(name)")
            } else {
                print(name)
            }
        }
    }
}

struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a folder and everything in it.")

    @Argument(help: "Folder in the drive.")
    var path = "/"

    @Option(help: When.help("Show it"), transform: When.parse)
    var at: Date?

    func run() async throws {
        let tree = try await Context.load().tree(at: at)
        let path = DrivePath(path)
        let start = try tree.locate(path)
        if let start, !start.isFolder { throw ATDriveError.notAFolder(path.description) }
        var folders = 0
        var files = 0
        var bytes = 0
        func walk(_ folder: String?, prefix: String) {
            let children = tree.children(of: folder)
            for (index, node) in children.enumerated() {
                let last = index == children.count - 1
                if node.isFolder {
                    folders += 1
                    print("\(prefix)\(last ? "└── " : "├── ")\(node.name)/")
                    walk(node.id, prefix: prefix + (last ? "    " : "│   "))
                } else {
                    files += 1
                    bytes += node.record.size ?? 0
                    print("\(prefix)\(last ? "└── " : "├── ")\(node.name)  (\(Output.size(node.record.size ?? 0)))")
                }
            }
        }
        print(at.map { "\(path)  (as of \(Output.date($0)))" } ?? path.description)
        walk(start?.id, prefix: "")
        print(
            "\n\(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s"), \(Output.size(bytes))"
        )
        // They exist, but where (and what's in them) can't be shown.
        if !tree.unreadable.isEmpty {
            let count = tree.unreadable.count
            print(
                "(\(count) item\(count == 1 ? "" : "s") in the drive can't be read here: made by a newer atdrive, or sealed with a key this device doesn't have)"
            )
        }
    }
}

struct Put: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload files or folders.",
        discussion: """
            Works like cp: the last argument is where to put them (default: the top of the drive).
              atdrive put notes.txt                 → /notes.txt
              atdrive put notes.txt /docs/          → /docs/notes.txt
              atdrive put notes.txt /docs/todo.txt  → /docs/todo.txt
              atdrive put -r Photos /backup         → /backup/Photos/... (if /backup exists)
            Existing files are replaced in place; unchanged ones are skipped.

            Inside the folders it uploads, it leaves out what's ignored, as git does:
            - what .atdriveignore files ignore (always);
            - what .gitignore files ignore (unless ignore.respect_gitignore = false in config.toml);
            - ignore.patterns in config.toml, as if in a .atdriveignore at the top. By default, what file browsers and editors leave around (.DS_Store, swap and lock files); `atdrive config` lists them.
            In one folder, .atdriveignore wins over .gitignore, so `!.env` in it brings back a .env that git ignores.

            --include-ignored turns all of that off for this upload:
              atdrive put -r myapp /code                    → leaves out myapp/build/, myapp/.env, … (what's ignored)
              atdrive put -r --include-ignored myapp /code  → uploads everything in myapp
            Something you name on the command line is uploaded even if it's ignored (`atdrive put .env`).

            Never uploaded: a synced folder's own .atdrive folder (at the top of what you upload), and half-finished downloads (*.atdrive-partial).
            """
    )

    @Argument(help: "Local files or folders, optionally followed by a destination in the drive.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Upload folders and everything in them.")
    var recursive = false

    @Flag(help: "Leave nothing out: upload what's ignored too (see above).")
    var includeIgnored = false

    func validate() throws {
        if paths.isEmpty { throw ValidationError("nothing to upload") }
    }

    func run() async throws {
        // A config.toml that can't be read stops it, rather than upload what it may ignore.
        let ignore = includeIgnored || !recursive ? IgnoreSettings.none : try ConfigFile.standard().load().ignore
        let drive = try await Context.load().joined
        let sources = paths.count == 1 ? paths : Array(paths.dropLast())
        let destination = DrivePath(paths.count == 1 ? "/" : paths.last!)
        let tree = try await drive.tree()
        var uploader = Uploader(
            drive: drive, state: DriveState(tree), recursive: recursive, ignore: ignore, known: tree.chunkCIDs)

        let target = try tree.find(destination)
        for source in sources {
            let local = URL(fileURLWithPath: source)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else {
                throw ATDriveError.notFound(source)
            }
            let name = local.standardizedFileURL.lastPathComponent
            switch target {
            case .root:
                try await uploader.upload(
                    local, isDirectory: isDirectory.boolValue, as: name, in: nil, at: destination.appending(name))
            case .node(let folder) where folder.isFolder:
                try await uploader.upload(
                    local, isDirectory: isDirectory.boolValue, as: name, in: folder.id, at: destination.appending(name))
            case .node(let file):
                guard sources.count == 1, !isDirectory.boolValue else {
                    throw ATDriveError.notAFolder(destination.description)
                }
                try await uploader.upload(
                    local, isDirectory: false, as: file.name, in: file.record.parent, at: destination)
            case .missing:
                guard sources.count == 1, let newName = destination.name else {
                    throw ATDriveError.notFound(destination.description)
                }
                let parent: String?
                switch try tree.find(destination.parent) {
                case .root: parent = nil
                case .node(let folder) where folder.isFolder: parent = folder.id
                case .node: throw ATDriveError.notAFolder(destination.parent.description)
                case .missing: throw ATDriveError.notFound(destination.parent.description)
                }
                try await uploader.upload(
                    local, isDirectory: isDirectory.boolValue, as: newName, in: parent, at: destination)
            }
        }
    }
}

struct Uploader {
    let drive: JoinedDrive
    var state: DriveState
    let recursive: Bool
    /// What's left out inside a folder being uploaded (and `SyncIgnore`'s names, always).
    let ignore: IgnoreSettings
    /// Chunks the drive has: those current files use, and those uploaded since.
    var known: Set<String>
    /// The folder being uploaded (named on the command line), and its ignore rules so far.
    private var top = ""
    private var rules = IgnoreRules(.none)

    init(drive: JoinedDrive, state: DriveState, recursive: Bool, ignore: IgnoreSettings, known: Set<String>) {
        self.drive = drive
        self.state = state
        self.recursive = recursive
        self.ignore = ignore
        self.known = known
    }

    mutating func upload(_ local: URL, isDirectory: Bool, as name: String, in parent: String?, at path: DrivePath)
        async throws
    {
        if isDirectory {
            guard recursive else { throw ATDriveError.needsRecursive(local.relativePath) }
            top = local.standardizedFileURL.path
            rules = IgnoreRules(ignore)
            try await uploadFolder(local, as: name, in: parent, at: path, relative: "")
        } else {
            try await uploadFile(local, as: name, in: parent, at: path)
        }
    }

    private mutating func uploadFile(_ local: URL, as name: String, in parent: String?, at path: DrivePath)
        async throws
    {
        let existing = state.child(named: name, in: parent)
        if let existing, existing.isFolder { throw ATDriveError.isAFolder(path.description) }
        if let existing, try drive.isUnchanged(local, comparedTo: existing) {
            print("= \(path)  (unchanged)")
            return
        }
        let node = try await drive.upload(
            local, as: name, in: parent, replacing: existing, known: known, progress: Output.progress("↑", path))
        for chunk in node.record.chunks ?? [] { known.insert(chunk.cid) }
        Output.clearStatus()
        state.add(node)
        print("↑ \(path)  (\(Output.size(node.record.size ?? 0)))")
    }

    /// `relative`: where it is in the folder named on the command line (`""` for that one).
    private mutating func uploadFolder(
        _ local: URL, as name: String, in parent: String?, at path: DrivePath, relative: String
    ) async throws {
        let folder: Node
        switch state.child(named: name, in: parent) {
        case let existing? where existing.isFolder:
            folder = existing
        case .some:
            throw ATDriveError.alreadyExists(path.description)
        case nil:
            folder = try await drive.createFolder(named: name, in: parent)
            state.add(folder)
            print("+ \(path)/")
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: local, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        rules.read(folder: relative, in: top, names: Set(entries.map(\.lastPathComponent)))
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let childName = entry.lastPathComponent
            let childPath = path.appending(childName)
            let childRelative = relative.isEmpty ? childName : "\(relative)/\(childName)"
            if SyncIgnore.isIgnored(childName, atTop: relative.isEmpty) { continue }
            if values.isSymbolicLink != true, rules.matches(childRelative, isFolder: values.isDirectory == true) {
                print("- \(childPath)\(values.isDirectory == true ? "/" : "")  (ignored)")
                continue
            }
            if values.isSymbolicLink == true {
                Output.warn("skipping symlink \(entry.path)")
            } else if values.isDirectory == true {
                try await uploadFolder(entry, as: childName, in: folder.id, at: childPath, relative: childRelative)
            } else if values.isRegularFile == true {
                try await uploadFile(entry, as: entry.lastPathComponent, in: folder.id, at: childPath)
            } else {
                Output.warn("skipping special file \(entry.path)")
            }
        }
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download files or folders.",
        discussion: """
            Works like cp: the last argument is where to save them (default: the current folder).
              atdrive get /notes.txt                → ./notes.txt
              atdrive get -r /Photos ~/Pictures     → ~/Pictures/Photos/...
              atdrive get -r / ./backup             → everything, into ./backup
            Files that are already identical locally are skipped.

            Given a link someone shared (atdrive://…), downloads what it shares into the folder:
              atdrive get 'atdrive://open?at=…' ~/Downloads
            That works signed out, for a link that's on.
            """
    )

    @Argument(help: "Paths in the drive, optionally followed by a local destination.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Download folders and everything in them.")
    var recursive = false

    @Option(help: When.help("Download them"), transform: When.parse)
    var at: Date?

    func validate() throws {
        if paths.isEmpty { throw ValidationError("nothing to download") }
    }

    func run() async throws {
        if let first = paths.first, first.hasPrefix("atdrive://") || first.hasPrefix("at://") {
            // A link: download what it shares, once (signed out for a public link).
            guard paths.count <= 2 else { throw ValidationError("one link at a time") }
            return try await LinkDownload.run(first, to: URL(fileURLWithPath: paths.count == 2 ? paths[1] : "."))
        }
        let context = try await Context.load()
        let drive = context.joined
        let tree = try await context.tree(at: at)
        let sources = paths.count == 1 ? paths : Array(paths.dropLast())
        let destination = URL(fileURLWithPath: paths.count == 1 ? "." : paths.last!)
        var isDirectory: ObjCBool = false
        let destinationExists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if sources.count > 1, !(destinationExists && isDirectory.boolValue) {
            throw ATDriveError.notAFolder(destination.relativePath)
        }

        for source in sources {
            let path = DrivePath(source)
            let node = try tree.locate(path)
            // Into an existing local folder: keep the name. Otherwise the destination is the new name.
            let target =
                destinationExists && isDirectory.boolValue && node != nil
                ? destination.appendingPathComponent(node!.name) : destination
            if let node, !node.isFolder {
                try await download(node, at: path, to: target, drive: drive)
            } else {
                guard recursive else { throw ATDriveError.needsRecursive(path.description) }
                try await downloadFolder(node?.id, at: path, to: target, tree: tree, drive: drive)
            }
        }
    }

    private func downloadFolder(
        _ folder: String?, at path: DrivePath, to local: URL, tree: DriveTree, drive: JoinedDrive
    )
        async throws
    {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for child in tree.children(of: folder) {
            let target = local.appendingPathComponent(child.name)
            if child.isFolder {
                try await downloadFolder(child.id, at: path.appending(child.name), to: target, tree: tree, drive: drive)
            } else {
                try await download(child, at: path.appending(child.name), to: target, drive: drive)
            }
        }
    }

    private func download(_ node: Node, at path: DrivePath, to local: URL, drive: JoinedDrive) async throws {
        if FileManager.default.fileExists(atPath: local.path), try drive.isUnchanged(local, comparedTo: node) {
            print("= \(local.relativePath)  (unchanged)")
            return
        }
        // What the copy here has already isn't fetched again.
        let previous = FileManager.default.fileExists(atPath: local.path) ? local : nil
        try await drive.download(node, to: local, previous: previous, progress: Output.progress("↓", path))
        Output.clearStatus()
        print("↓ \(local.relativePath)  (\(Output.size(node.record.size ?? 0)))")
    }
}

struct Cat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a file to standard output.")

    @Argument(help: "File in the drive.")
    var path: String

    @Option(help: When.help("Print it"), transform: When.parse)
    var at: Date?

    func run() async throws {
        let context = try await Context.load()
        let drive = context.joined
        let path = DrivePath(path)
        guard let node = try await context.tree(at: at).locate(path) else {
            throw ATDriveError.isAFolder(path.description)
        }
        try await drive.read(node) { FileHandle.standardOutput.write($0) }
    }
}

struct MakeFolder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mkdir", abstract: "Create folders.")

    @Argument(help: "Folders to create.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Create missing parent folders too; no error if it exists.")
    var parents = false

    func run() async throws {
        let drive = try await Context.load().joined
        var state = DriveState(try await drive.tree())
        for raw in paths {
            let path = DrivePath(raw)
            guard !path.isRoot else { continue }
            var current: String? = nil
            for (index, name) in path.components.enumerated() {
                let isLast = index == path.components.count - 1
                let prefix = DrivePath(path.components[...index].joined(separator: "/"))
                if let existing = state.child(named: name, in: current) {
                    guard existing.isFolder else { throw ATDriveError.notAFolder(prefix.description) }
                    if isLast, !parents { throw ATDriveError.alreadyExists(prefix.description) }
                    current = existing.id
                } else {
                    guard isLast || parents else { throw ATDriveError.notFound(prefix.description) }
                    let folder = try await drive.createFolder(named: name, in: current)
                    state.add(folder)
                    print("+ \(prefix)/")
                    current = folder.id
                }
            }
        }
    }
}

struct Move: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv", abstract: "Rename or move a file or folder.",
        discussion: """
              atdrive mv /notes.txt /todo.txt       rename
              atdrive mv /notes.txt /docs/          move into a folder
            """
    )

    @Argument(help: "What to move.")
    var source: String

    @Argument(help: "New path, or an existing folder to move it into.")
    var destination: String

    func run() async throws {
        let drive = try await Context.load().joined
        let tree = try await drive.tree()
        let from = DrivePath(source)
        let to = DrivePath(destination)
        guard let node = try tree.locate(from) else {
            throw ATDriveError.invalidMove("can't move the top of the drive")
        }

        let parent: String?
        let name: String
        switch try tree.find(to) {
        case .root:
            (parent, name) = (nil, node.name)
        case .node(let folder) where folder.isFolder && folder.id != node.id:
            (parent, name) = (folder.id, node.name)
        case .node(let existing) where existing.id == node.id:
            return
        case .node:
            throw ATDriveError.alreadyExists(to.description)
        case .missing:
            switch try tree.find(to.parent) {
            case .root: parent = nil
            case .node(let folder) where folder.isFolder: parent = folder.id
            case .node: throw ATDriveError.notAFolder(to.parent.description)
            case .missing: throw ATDriveError.notFound(to.parent.description)
            }
            name = to.name!
        }
        if node.isFolder, let parent, tree.isInside(parent, folder: node.id) {
            throw ATDriveError.invalidMove("can't move \(from) inside itself")
        }
        if let clash = tree.child(named: name, in: parent), clash.id != node.id {
            throw ATDriveError.alreadyExists(tree.path(of: clash).description)
        }
        try await drive.move(node, to: parent, as: name)
        let folderPath = parent.flatMap { tree.nodes[$0] }.map(tree.path(of:)) ?? .root
        print("\(from) → \(folderPath.appending(name))")
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Delete files or folders (they go to the trash).",
        discussion: """
            Deleted things stay in the trash for \(DriveSettings.defaultRetentionDays) days, as long as the drive keeps history. `atdrive trash` lists them, and `atdrive restore <path>` brings one back. To get rid of something for good, `atdrive trash empty <path>` after deleting it.
            """
    )

    @Argument(help: "Paths in the drive.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Delete folders and everything in them.")
    var recursive = false

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation (deleting something you share).")
    var yes = false

    func run() async throws {
        let drive = try await Context.load().joined
        let snapshot = try await drive.update(nil)
        let tree = snapshot.tree
        // Check every path before deleting anything.
        var targets: [(DrivePath, [Node])] = []
        for raw in paths {
            let path = DrivePath(raw)
            guard let node = try tree.locate(path) else {
                throw ATDriveError.invalidMove("refusing to delete the whole drive")
            }
            // Something shared with you only leaves your drive: no -r needed.
            let theirs = node.isMount && snapshot.mounts[node.id]?.readOnly == true
            if node.isFolder, !recursive, !theirs { throw ATDriveError.needsRecursive(path.description) }
            targets.append((path, node.isFolder && !theirs ? tree.descendants(of: node.id) + [node] : [node]))
        }
        // Deleting something you share stops sharing it: say who loses it, and ask.
        let ids = Set(targets.map { $0.1.last!.id })
        let shared = try await drive.ownShares(in: snapshot).filter { ids.contains($0.mount.id) }
        if !shared.isEmpty, !yes {
            var lines: [String] = []
            for share in shared {
                let who = await Unshare.whoHasIt(share)
                lines.append("\(share.path): \(who.isEmpty ? "shared, with nobody yet" : "\(who) will lose it")")
            }
            guard try Output.confirm("Deleting stops sharing these. Delete them?", about: lines) else {
                print("Nothing was deleted.")
                return
            }
        }
        for (path, nodes) in targets {
            try await drive.delete(nodes)
            print("✗ \(path)\(nodes.count > 1 ? "  (\(nodes.count) items)" : "")")
        }
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

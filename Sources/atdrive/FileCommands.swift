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
            print("(\(count) item\(count == 1 ? "" : "s") in the drive can't be read by this version of atdrive)")
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
            """
    )

    @Argument(help: "Local files or folders, optionally followed by a destination in the drive.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Upload folders and everything in them.")
    var recursive = false

    func validate() throws {
        if paths.isEmpty { throw ValidationError("nothing to upload") }
    }

    func run() async throws {
        let drive = try await Context.load().drive
        let sources = paths.count == 1 ? paths : Array(paths.dropLast())
        let destination = DrivePath(paths.count == 1 ? "/" : paths.last!)
        let tree = try await drive.tree()
        var uploader = Uploader(drive: drive, state: DriveState(tree), recursive: recursive)

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
    let drive: Drive
    var state: DriveState
    let recursive: Bool

    mutating func upload(_ local: URL, isDirectory: Bool, as name: String, in parent: String?, at path: DrivePath)
        async throws
    {
        if isDirectory {
            guard recursive else { throw ATDriveError.needsRecursive(local.relativePath) }
            try await uploadFolder(local, as: name, in: parent, at: path)
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
            local, as: name, in: parent, replacing: existing, progress: Output.progress("↑", path))
        Output.clearStatus()
        state.add(node)
        print("↑ \(path)  (\(Output.size(node.record.size ?? 0)))")
    }

    private mutating func uploadFolder(_ local: URL, as name: String, in parent: String?, at path: DrivePath)
        async throws
    {
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
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let childPath = path.appending(entry.lastPathComponent)
            if values.isSymbolicLink == true {
                Output.warn("skipping symlink \(entry.path)")
            } else if values.isDirectory == true {
                try await uploadFolder(entry, as: entry.lastPathComponent, in: folder.id, at: childPath)
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
        let context = try await Context.load()
        let drive = context.drive
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

    private func downloadFolder(_ folder: String?, at path: DrivePath, to local: URL, tree: DriveTree, drive: Drive)
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

    private func download(_ node: Node, at path: DrivePath, to local: URL, drive: Drive) async throws {
        if FileManager.default.fileExists(atPath: local.path), try drive.isUnchanged(local, comparedTo: node) {
            print("= \(local.relativePath)  (unchanged)")
            return
        }
        try await drive.download(node, to: local, progress: Output.progress("↓", path))
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
        let drive = context.drive
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
        let drive = try await Context.load().drive
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
        let drive = try await Context.load().drive
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
            Deleted things stay in the trash for \(DriveSettings.defaultRetentionDays) days, as long as the drive keeps history. `atdrive trash` lists them, and `atdrive trash restore <path>` brings them back. To delete something for good right away, use `atdrive purge`.
            """
    )

    @Argument(help: "Paths in the drive.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Delete folders and everything in them.")
    var recursive = false

    func run() async throws {
        let drive = try await Context.load().drive
        let tree = try await drive.tree()
        // Check every path before deleting anything.
        var targets: [(DrivePath, [Node])] = []
        for raw in paths {
            let path = DrivePath(raw)
            guard let node = try tree.locate(path) else {
                throw ATDriveError.invalidMove("refusing to delete the whole drive")
            }
            if node.isFolder, !recursive { throw ATDriveError.needsRecursive(path.description) }
            targets.append((path, node.isFolder ? tree.descendants(of: node.id) + [node] : [node]))
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

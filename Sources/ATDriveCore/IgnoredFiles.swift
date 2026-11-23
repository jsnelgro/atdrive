import Foundation

/// What's ignored (`atdrive dev list-ignored`, `delete-ignored`): the outermost ignored things
/// only (an ignored folder, not also everything in it), sorted by path.
public enum IgnoredFiles {
    /// Something ignored in a local folder.
    public struct Item: Sendable, Equatable {
        /// Relative to the folder.
        public var path: String
        public var isFolder: Bool
    }

    /// In a local folder, as `atdrive sync` sees it: by the ignore files in it and the settings.
    /// What ATDrive uses itself (`SyncIgnore`) never counts, nor do symlinks and the like (which
    /// aren't synced anyway).
    public static func local(in root: String, settings: IgnoreSettings) throws -> [Item] {
        try FolderScan(root: root, ignore: settings).ignored.map { Item(path: $0.path, isFolder: $0.isFolder) }
            .sorted { $0.path < $1.path }
    }

    /// In the drive, by the ignore files in it and the settings (as the Mac app sees it). Your own
    /// files and folders only: not shares (yours or other people's, nor what's in them) or the
    /// Spaces folder. `read` gives an ignore file's text.
    public static func inDrive(
        _ tree: DriveTree, settings: IgnoreSettings, read: (Node) async throws -> String
    ) async throws -> [Node] {
        func own(_ node: Node) -> Bool {
            NodeID.split(node.id).mount == nil && node.id != SpacesFolder.id && !node.isMount
        }
        func path(_ node: Node) -> [String] { tree.path(of: node).components }

        // Every ignore file, by the folder it's in.
        var byFolder: [String: (atdriveignore: Node?, gitignore: Node?)] = [:]
        for node in tree.nodes.values where own(node) && !node.isFolder {
            let folder = path(node).dropLast().joined(separator: "/")
            if node.name == IgnoreRules.fileName {
                byFolder[folder, default: (nil, nil)].atdriveignore = node
            } else if settings.respectGitignore, node.name == IgnoreRules.gitFileName {
                byFolder[folder, default: (nil, nil)].gitignore = node
            }
        }
        func text(_ node: Node?) async throws -> String? {
            guard let node, (node.record.size ?? 0) <= IgnoreRules.maximumFileSize else { return nil }
            return try await read(node)
        }
        var rules = IgnoreRules(settings)
        for (folder, files) in byFolder {
            rules.add(
                folder: folder, atdriveignore: try await text(files.atdriveignore),
                gitignore: try await text(files.gitignore))
        }

        var lookup = IgnoreRules.Lookup(rules)
        var found: [(path: [String], node: Node)] = []
        for node in tree.nodes.values where own(node) {
            let components = path(node)
            guard lookup.isIgnored(components, isFolder: node.isFolder) else { continue }
            // Outermost only: what's in an ignored folder goes with it.
            if components.count > 1, lookup.isIgnored(Array(components.dropLast()), isFolder: true) { continue }
            found.append((components, node))
        }
        return found.sorted { $0.path.lexicographicallyPrecedes($1.path) }.map(\.node)
    }
}

// MARK: atdrive dev list-ignored / delete-ignored

extension IgnoredFiles {
    /// The synced folder to look in, and how it was found.
    public enum Folder: Sendable, Equatable {
        /// Named on the command line.
        case named(String)
        /// The one `atdrive sync --install` set up.
        case installed(String)
        /// `~/atdrive`, the default.
        case standard(String)
        /// None: `installedElsewhere` is the folder `atdrive sync --install` set up, which isn't
        /// synced with this drive (`nil`: there's none, and `~/atdrive` isn't synced either).
        case none(installedElsewhere: String?)

        public var path: String? {
            switch self {
            case .named(let path), .installed(let path), .standard(let path): path
            case .none: nil
            }
        }
    }

    public struct NotSynced: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) isn't a folder `atdrive sync` keeps in sync with this drive" }
    }

    /// Picks the synced folder: the one `named`, or else the one `atdrive sync --install` set up
    /// (`installed`), or else `standard` (`~/atdrive`). Only ever one `atdrive sync` keeps in sync
    /// with `drive`, so no other folder can be cleaned out by mistake: a named one that isn't
    /// throws `NotSynced`.
    public static func folder(named: String?, installed: String?, standard: String, drive: Drive) throws -> Folder {
        func clean(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        if let named {
            guard FolderSync.isSynced(clean(named), with: drive) else { throw NotSynced(path: clean(named)) }
            return .named(clean(named))
        }
        if let installed {
            return FolderSync.isSynced(clean(installed), with: drive)
                ? .installed(clean(installed)) : .none(installedElsewhere: clean(installed))
        }
        return FolderSync.isSynced(clean(standard), with: drive)
            ? .standard(clean(standard)) : .none(installedElsewhere: nil)
    }

    /// What's ignored, in the synced folder and in the drive.
    public struct Found: Sendable {
        public var folder: Folder
        public var local: [Item]
        /// Outermost first by path; see `inDrive`.
        public var remote: [Node]
        /// The drive as it was looked at.
        public var tree: DriveTree

        public var isEmpty: Bool { local.isEmpty && remote.isEmpty }
        public var count: Int { local.count + remote.count }
    }

    /// Finds what's ignored, in `folder` and in the drive.
    public static func find(in drive: JoinedDrive, folder: Folder, settings: IgnoreSettings) async throws -> Found {
        let tree = try await drive.update(nil).tree
        let local = try folder.path.map { try self.local(in: $0, settings: settings) } ?? []
        let remote = try await inDrive(tree, settings: settings) { node in
            var data = Data()
            try await drive.read(node) { data += $0 }
            return String(decoding: data, as: UTF8.self)
        }
        return Found(folder: folder, local: local, remote: remote, tree: tree)
    }

    /// One thing deleted, or not.
    public struct Deletion: Sendable, Equatable {
        /// Relative to the synced folder, or (`inDrive`) the drive path.
        public var path: String
        public var isFolder: Bool
        public var inDrive: Bool
        /// Files and folders it took, itself included.
        public var count: Int
        /// Why it's still there; `nil` once it's gone.
        public var problem: String?
    }

    /// Deletes what was found: what's in the drive to the drive's trash, what's in the synced
    /// folder (never in the drive) to `trash`, this computer's. Something local that can't be
    /// moved is left where it is and reported with its problem; a drive that can't be written
    /// stops it (throws).
    public static func delete(
        _ found: Found, in drive: JoinedDrive,
        trash: (String) throws -> Void = { try SystemTrash.move($0) },
        report: (Deletion) -> Void
    ) async throws {
        if let root = found.folder.path {
            for item in found.local {
                var deletion = Deletion(path: item.path, isFolder: item.isFolder, inDrive: false, count: 1)
                do {
                    try trash("\(root)/\(item.path)")
                } catch {
                    deletion.problem = "\(error)"
                }
                report(deletion)
            }
        }
        for node in found.remote {
            let nodes = node.isFolder ? found.tree.descendants(of: node.id) + [node] : [node]
            try await drive.delete(nodes)
            report(
                Deletion(
                    path: found.tree.path(of: node).description, isFolder: node.isFolder, inDrive: true,
                    count: nodes.count))
        }
    }
}

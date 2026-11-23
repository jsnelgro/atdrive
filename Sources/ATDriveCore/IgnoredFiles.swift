import Foundation

/// What's ignored, to delete it (`atdrive dev delete-ignored`): the outermost ignored things
/// only (an ignored folder, not also everything in it), sorted by path.
public enum IgnoredFiles {
    /// In a local folder, as `atdrive sync` sees it: by the ignore files in it and the settings.
    /// What ATDrive uses itself (`SyncIgnore`) never counts, nor do symlinks and the like (which
    /// aren't synced anyway). Paths are relative to `root`.
    public static func local(in root: String, settings: IgnoreSettings) throws -> [(path: String, isFolder: Bool)] {
        try FolderScan(root: root, ignore: settings).ignored.sorted { $0.path < $1.path }
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

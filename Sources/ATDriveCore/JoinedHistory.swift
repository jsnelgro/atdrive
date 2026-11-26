import Foundation

/// History and the trash across the joined drive (#11): for the Mac app's Trash window and
/// Finder's "Restore Previous Version…". History is kept per space (`DriveSnapshot`); these find
/// the space a node is in, and give what they find under joined node IDs (`NodeID`) and paths.
///
/// Only the spaces this account writes have history to restore: the home drive and its own
/// shares. Other people's shares are read-only, and the Spaces folder has none.
extension JoinedSnapshot {
    /// Something in the trash of one of the account's spaces.
    public struct TrashItem: Sendable, Equatable, Identifiable {
        /// As its space has it.
        public var item: DriveHistory.TrashItem
        /// The mount of the space it's in; `nil`: the home drive.
        public var mount: String?
        /// Where it was, in the joined drive, just before it was deleted.
        public var path: DrivePath
        /// How many things were deleted along with it (what was in a folder). They come back
        /// with it.
        public var inside: Int

        /// Its joined node ID: what `JoinedDrive.restoreFromTrash` takes.
        public var id: String { NodeID.join(mount, item.id) }
        public var name: String { item.name }
        public var isFolder: Bool { item.isFolder }
        public var deletedAt: Date { item.deletedAt }
        /// A file's size; `nil` for a folder.
        public var size: Int? { isFolder ? nil : item.record.size ?? 0 }
        /// The device that deleted it.
        public var device: String { item.deletion.record.device }
        /// The folder it was in.
        public var folder: DrivePath { path.parent }
    }

    /// What's in the trash of every space this account writes, newest first. Things deleted
    /// along with their folder aren't listed: they come back with it (`TrashItem.inside`).
    public func trash(now: Date = Date()) -> [TrashItem] {
        var items: [TrashItem] = []
        for (mount, snapshot, prefix) in writableSpaces() {
            let all = snapshot.trash(now: now)
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for item in all where !item.deletedWithFolder {
                let inside = item.isFolder ? snapshot.history.deletedTogether(item.id, trash: byID).count - 1 : 0
                items.append(
                    TrashItem(
                        item: item, mount: mount, path: DrivePath(components: prefix + item.path.components),
                        inside: inside))
            }
        }
        return items.sorted { ($0.deletedAt, $0.id) > ($1.deletedAt, $1.id) }
    }

    /// The spaces this account writes, readable now: each with its mount (`nil`: the home
    /// drive), snapshot, and where it is in the joined drive. A share of one file isn't listed:
    /// its space holds that file, whose history is the file's (`history(of:)`).
    private func writableSpaces() -> [(mount: String?, snapshot: DriveSnapshot, prefix: [String])] {
        var spaces: [(String?, DriveSnapshot, [String])] = [(nil, home, [])]
        for (id, state) in mounts.sorted(by: { $0.key < $1.key }) {
            guard !state.readOnly, state.problem == nil, let snapshot = state.snapshot,
                Self.sharedFile(state) == nil, let node = tree.nodes[id]
            else { continue }
            spaces.append((id, snapshot, tree.path(of: node).components))
        }
        return spaces
    }

    /// Where a node's history is kept: the mount of its space (`nil`: the home drive), that
    /// space's snapshot, and the node's ID there. A share of one file of yours has the history of
    /// the file in its space. `nil` when there's none this account can restore from: other
    /// people's shares, the Spaces folder, a share of a folder (its history is what's in it), or
    /// a space that can't be read now.
    public func history(of id: String) -> (mount: String?, snapshot: DriveSnapshot, node: String)? {
        if SpacesFolder.contains(id) { return nil }
        let (mount, rkey) = NodeID.split(id)
        guard let mount else {
            guard let node = home.tree.nodes[rkey] else { return nil }
            guard node.isMount else { return (nil, home, rkey) }
            guard let state = mounts[rkey], !state.readOnly, state.problem == nil, let snapshot = state.snapshot,
                let file = Self.sharedFile(state)
            else { return nil }
            return (rkey, snapshot, file.id)
        }
        guard let state = mounts[mount], !state.readOnly, state.problem == nil, let snapshot = state.snapshot,
            Self.sharedFile(state) == nil, snapshot.tree.nodes[rkey] != nil
        else { return nil }
        return (mount, snapshot, rkey)
    }

    /// A version of a file, for choosing one to restore.
    public struct FileVersion: Sendable, Equatable, Identifiable {
        /// The change that made these contents.
        public var entry: DriveHistory.Entry
        /// These are the contents it has now.
        public var isCurrent: Bool
        /// They can still be read (`DriveHistory.contentsAvailable`): history older than the
        /// drive keeps may be gone.
        public var available: Bool

        public var id: String { entry.id }
        public var version: Version { entry.version }
        public var date: Date { entry.date }
        public var size: Int { entry.record?.size ?? 0 }
        public var device: String { entry.device }
    }

    /// A file's versions, newest first: each change that gave it other contents (made, edited,
    /// restored). Renames and moves aren't versions. Empty for something with no history here
    /// (`history(of:)`) or a folder.
    public func versions(of id: String) -> [FileVersion] {
        guard let (_, snapshot, node) = history(of: id), let current = snapshot.tree.nodes[node], !current.isFolder
        else { return [] }
        let history = snapshot.history
        var versions: [FileVersion] = []
        let contentChanges: Set<VersionRecord.Change> = [.created, .edited, .restored]
        var previous: NodeRecord?
        for entry in snapshot.entries(.node(node)).reversed() {
            guard contentChanges.contains(entry.change), let record = entry.record, record.kind == .file else {
                continue
            }
            // A restore that only put back its name or place, or an edit to the same contents.
            if !entry.lost, let previous, previous.sha256 == record.sha256, previous.size == record.size { continue }
            if !entry.lost { previous = record }
            versions.append(
                FileVersion(entry: entry, isCurrent: false, available: history.contentsAvailable(entry.version)))
        }
        // The newest version on its line with the contents it has now.
        if let index = versions.lastIndex(where: {
            !$0.entry.lost && $0.entry.record?.sha256 == current.record.sha256
                && $0.entry.record?.size == current.record.size
        }) {
            versions[index].isCurrent = true
        }
        return versions.reversed()
    }

    /// Changes to a folder and to everything that was in it at the time, newest first, with
    /// paths in the joined drive. Empty for something with no history here (`history(of:)`).
    public func changes(in folder: String) -> [DriveHistory.Entry] {
        guard let (mount, snapshot, node) = history(of: folder) else { return [] }
        let prefix = mount.flatMap { tree.nodes[$0] }.map { tree.path(of: $0).components } ?? []
        return snapshot.entries(.folder(node)).map { entry in
            var entry = entry
            entry.path = entry.path.map { DrivePath(components: prefix + $0.components) }
            return entry
        }
    }
}

extension JoinedDrive {
    /// Brings things back from the trash where they were (see `Drive.restoreFromTrash`), each in
    /// its space. `ids` are `JoinedSnapshot.TrashItem.id`s; what's restored and skipped comes back
    /// under joined IDs.
    @discardableResult
    public func restoreFromTrash(_ ids: [String], in snapshot: JoinedSnapshot) async throws -> Drive.RestoreResult {
        var bySpace: [String?: [String]] = [:]
        for id in ids {
            let (mount, rkey) = NodeID.split(id)
            bySpace[mount, default: []].append(rkey)
        }
        var result = Drive.RestoreResult(restored: [], skipped: [])
        for (mount, ids) in bySpace.sorted(by: { ($0.key ?? "") < ($1.key ?? "") }) {
            let (drive, space) = try writableSpace(mount, in: snapshot)
            result.add(try await drive.restoreFromTrash(ids, in: space), from: mount, joining: self)
        }
        return result
    }

    /// Puts a file's contents back as `version` left them, keeping its name and place (see
    /// `Drive.restoreContents`). `version` is one of `JoinedSnapshot.versions(of: id)`.
    @discardableResult
    public func restoreContents(of id: String, from version: Version, in snapshot: JoinedSnapshot) async throws
        -> Drive.RestoreResult
    {
        guard let (mount, _, node) = snapshot.history(of: id) else { throw ATDriveError.notFound(id) }
        let (drive, space) = try writableSpace(mount, in: snapshot)
        var result = Drive.RestoreResult(restored: [], skipped: [])
        result.add(try await drive.restoreContents(of: node, from: version, in: space), from: mount, joining: self)
        return result
    }

    /// Puts a file or folder back as it was at `date`, with what was in it then (see
    /// `Drive.restore(_:asOf:in:)`), in its space.
    @discardableResult
    public func restore(_ id: String, asOf date: Date, in snapshot: JoinedSnapshot) async throws -> Drive.RestoreResult
    {
        guard let (mount, _, node) = snapshot.history(of: id) else { throw ATDriveError.notFound(id) }
        let (drive, space) = try writableSpace(mount, in: snapshot)
        var result = Drive.RestoreResult(restored: [], skipped: [])
        result.add(try await drive.restore(node, asOf: date, in: space), from: mount, joining: self)
        return result
    }

    /// The drive of a space this account writes, and its snapshot.
    private func writableSpace(_ mount: String?, in snapshot: JoinedSnapshot) throws -> (Drive, DriveSnapshot) {
        guard let mount else { return (home, snapshot.home) }
        let name = snapshot.tree.nodes[mount]?.name ?? mount
        let drive = try writable(mount, path: name)
        guard let space = snapshot.mounts[mount]?.snapshot else {
            throw ATDriveError.mountUnavailable(path: name, why: "it can't be read")
        }
        return (drive, space)
    }
}

extension Drive.RestoreResult {
    /// Adds what a restore in one space did, under joined IDs.
    fileprivate mutating func add(_ other: Drive.RestoreResult, from mount: String?, joining drive: JoinedDrive) {
        restored += other.restored.map { drive.global($0, in: mount) }
        skipped += other.skipped.map { NodeID.join(mount, $0) }
        for (id, reason) in other.reasons { reasons[NodeID.join(mount, id)] = reason }
    }
}

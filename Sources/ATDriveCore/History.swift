import Foundation

/// What the drive's history can do: settle races, restore things (from the trash, or as they
/// were at a time), purge, and prune. Each works from a `DriveSnapshot` brought up to date just
/// before (`Drive.update`), and writes only changes that are safe if another device does the
/// same thing at the same moment.
extension Drive {
    /// What a restore wrote.
    public struct RestoreResult: Sendable, Equatable {
        /// What was written, folders before what's in them.
        public var restored: [Node]
        /// What couldn't be: its contents are no longer in history, it can't be read here, or
        /// another device changed it at the same moment.
        public var skipped: [String]
    }

    // MARK: Races

    /// A race settled by `settleRaces`.
    public struct SettledRace: Sendable, Equatable {
        public var node: String
        /// The change that lost.
        public var lost: Version
        public var outcome: ConflictRules.LostChange
        /// What was written: the node, restored or given the lost contents, or the conflicted
        /// copy.
        public var written: Node
    }

    /// Finds changes that lost a race (another device's change, based on the same version, was
    /// written over them) and settles each with `ConflictRules.lostChange`: a lost edit comes
    /// back as a conflicted copy, or restores the file if it was deleted, and a lost move is
    /// dropped. Only races from within the retention period are settled.
    ///
    /// Idempotent, and safe when several devices do it at once: a conflicted copy's ID is the
    /// lost version's, and it and restores are created only if absent, so they're made once; a
    /// race is settled once its contents are on the node's line.
    @discardableResult
    public func settleRaces(in snapshot: DriveSnapshot, now: Date = Date()) async throws -> [SettledRace] {
        let history = snapshot.history
        let tree = snapshot.tree
        var settled: [SettledRace] = []
        /// Names given to copies in this pass, by folder: the snapshot doesn't have them.
        var named: [String?: Set<String>] = [:]
        for race in history.races(current: tree, since: TID.lowest(at: now - snapshot.retention))
        where !race.absorbed {
            let lost = history.record(at: race.lost)
            let current = tree.nodes[race.node]
            // Contents (hashes) on each side; `nil` where there was no node.
            var base: String?? = nil
            if let fork = race.fork, !fork.record.isDeletion { base = .some(fork.record.sha256) }
            let lostContents: String?? = lost.map(\.sha256)
            let currentContents: String?? = current.map(\.record.sha256)
            let outcome = ConflictRules.lostChange(base: base, lost: lostContents, current: currentContents)
            guard outcome != .dropped, let lost, history.contentsAvailable(race.lost) else { continue }
            var written: Node?
            switch outcome {
            case .dropped:
                continue
            case .restore:
                var plan = Restoration(drive: self, snapshot: snapshot)
                plan.restore(race.node, to: lost, in: plan.folder(lost.parent))
                written = try await plan.commit().restored.first { $0.id == race.node }
            case .contents:
                guard var record = current?.record else { continue }
                record.sha256 = lost.sha256
                record.size = lost.size
                record.chunks = lost.chunks
                record.contentsFrom = lost.contentsFrom
                record.modifiedAt = lost.modifiedAt
                written = try await commit(
                    [change(.update, node: race.node, record: record, .edited, prev: current?.record.version)]
                ).written.first
            case .conflictedCopy:
                let copy = race.lost.id
                guard let current, tree.nodes[copy] == nil, tree.unreadable[copy] == nil,
                    history.versions(of: copy).isEmpty
                else { continue }
                let parent = tree.parent(of: current.id)
                var record = lost
                record.parent = parent
                record.name = ConflictName.make(for: current.name, at: race.lost.date) {
                    tree.child(named: $0, in: parent) != nil || named[parent]?.contains($0) == true
                }
                named[parent, default: []].insert(record.name)
                written = try await commit(
                    [change(.create, node: copy, record: record, .created, prev: nil, newContents: true)]
                ).written.first
            }
            if let written {
                settled.append(SettledRace(node: race.node, lost: race.lost, outcome: outcome, written: written))
            }
        }
        return settled
    }

    // MARK: Restoring

    /// Brings back things from the trash, under their own IDs, where they were. A folder comes
    /// back with what was deleted with it, and deleted folders above anything restored come back
    /// too. Something whose name is taken by now gets a conflicted-copy name.
    @discardableResult
    public func restoreFromTrash(_ ids: [String], in snapshot: DriveSnapshot) async throws -> RestoreResult {
        var plan = Restoration(drive: self, snapshot: snapshot)
        var items: [DriveHistory.TrashItem] = []
        for id in ids {
            guard plan.trash[id] != nil else { throw ATDriveError.notFound(id) }
            items += snapshot.history.deletedTogether(id, trash: plan.trash)
        }
        for item in items where !plan.isPresent(item.id) {
            plan.restore(item.id, to: item.record, in: plan.folder(item.record.parent))
        }
        return try await plan.commit()
    }

    /// Puts a file, or a folder and everything that was in it, back as it was at `date`:
    /// contents, name and place. Things in it that were deleted since come back, and things
    /// moved since go back. (What was added to it since stays.) It's written as new versions,
    /// so it can be undone too.
    @discardableResult
    public func restore(_ id: String, asOf date: Date, in snapshot: DriveSnapshot) async throws -> RestoreResult {
        let past = snapshot.history.tree(at: date, current: snapshot.tree)
        guard let target = past.nodes[id] else { throw ATDriveError.notFound(id) }
        let inside = target.isFolder ? Array(past.descendants(of: id).reversed()) : []
        var plan = Restoration(drive: self, snapshot: snapshot)
        plan.release([id] + inside.map(\.id))
        var parent = plan.folder(target.record.parent)
        if let folder = parent, plan.isInside(folder, id) { parent = snapshot.tree.parent(of: id) }
        plan.restore(id, to: target.record, in: parent)
        for node in inside { plan.restore(node.id, to: node.record, in: plan.folder(past.parent(of: node.id))) }
        return try await plan.commit()
    }

    /// Undoes a node's latest change: puts it back as the change before left it (restores it
    /// if the latest change deleted it, and deletes it if it restored it).
    @discardableResult
    public func restorePrevious(_ id: String, in snapshot: DriveSnapshot) async throws -> RestoreResult {
        let history = snapshot.history
        guard let previous = history.previousVersion(of: id, current: snapshot.tree) else {
            throw ATDriveError.notFound(id)
        }
        guard let record = history.record(at: previous) else {
            if let node = snapshot.tree.nodes[id] {
                try await delete(snapshot.tree.descendants(of: id) + [node])
            }
            return RestoreResult(restored: [], skipped: [])
        }
        var plan = Restoration(drive: self, snapshot: snapshot)
        plan.release([id])
        var parent = plan.folder(record.parent)
        if let folder = parent, plan.isInside(folder, id) { parent = snapshot.tree.parent(of: id) }
        plan.restore(id, to: record, in: parent)
        return try await plan.commit()
    }

    // MARK: Deleting history

    /// Deletes files and folders now, and every version of them, so nothing of them can be
    /// restored: for a folder, everything in it too (or, in the trash, everything deleted with
    /// it). Returns how many records were deleted.
    @discardableResult
    public func purge(_ ids: [String], in snapshot: DriveSnapshot) async throws -> Int {
        let history = snapshot.history
        let tree = snapshot.tree
        let trash = Dictionary(history.trash(current: tree).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [String] = []
        var seen: Set<String> = []
        for id in ids {
            if let node = tree.nodes[id] {
                let inside = node.isFolder ? tree.descendants(of: id) : []
                for item in inside + [node] where seen.insert(item.id).inserted { nodes.append(item.id) }
            } else if trash[id] != nil {
                for item in history.deletedTogether(id, trash: trash).reversed() where seen.insert(item.id).inserted {
                    nodes.append(item.id)
                }
            } else if !history.versions(of: id).isEmpty || tree.unreadable[id] != nil {
                if seen.insert(id).inserted { nodes.append(id) }
            } else {
                throw ATDriveError.notFound(id)
            }
        }
        // Each node's versions oldest first, and its record with its newest: an interrupted
        // purge leaves it as it was with less history, never a node without its version.
        var groups: [[SpaceWrite]] = []
        for id in nodes {
            let versions = history.versions(of: id).map(\.id)
            for version in versions.dropLast() { groups.append([.delete(collection: Lexicon.version, rkey: version)]) }
            var last = versions.last.map { [SpaceWrite.delete(collection: Lexicon.version, rkey: $0)] } ?? []
            if tree.nodes[id] != nil || tree.unreadable[id] != nil {
                last.insert(.delete(collection: Lexicon.node, rkey: id), at: 0)
            }
            if !last.isEmpty { groups.append(last) }
        }
        return try await deleteRecords(groups)
    }

    /// Purges everything in the trash. Returns how many records were deleted.
    @discardableResult
    public func emptyTrash(in snapshot: DriveSnapshot) async throws -> Int {
        try await purge(snapshot.history.trash(current: snapshot.tree).map(\.id), in: snapshot)
    }

    /// Applies the retention period (`DriveSettings.retentionDays`): deletes the versions older
    /// than it, except what's needed to know the drive as it was when the period starts (see
    /// `DriveHistory.pruneable`). Deleting a version lets the server delete chunks nothing else
    /// uses. Any device may prune, even at the same time. Returns how many versions it deleted.
    @discardableResult
    public func prune(_ snapshot: DriveSnapshot, now: Date = Date()) async throws -> Int {
        let doomed = snapshot.history.pruneable(current: snapshot.tree, cutoff: now - snapshot.retention)
        return try await deleteRecords(doomed.map { [.delete(collection: Lexicon.version, rkey: $0)] })
    }

    /// Deletes records, in transactions of up to `maxWrites` that keep each group together.
    /// Records another device deleted first are skipped: a transaction that fails with
    /// `RecordNotFound` is split until the missing ones are found. Returns how many it deleted.
    func deleteRecords(_ groups: [[SpaceWrite]]) async throws -> Int {
        var deleted = 0
        var batch: [[SpaceWrite]] = []
        var count = 0
        for group in groups {
            if count + group.count > XRPCClient.maxWrites, !batch.isEmpty {
                deleted += try await deleteBatch(batch)
                batch = []
                count = 0
            }
            batch.append(group)
            count += group.count
        }
        if !batch.isEmpty { deleted += try await deleteBatch(batch) }
        return deleted
    }

    private func deleteBatch(_ groups: [[SpaceWrite]]) async throws -> Int {
        let writes = groups.flatMap { $0 }
        do {
            try await client.applySpaceWrites(space: space, repo: owner, writes: writes)
            return writes.count
        } catch let error as XRPCError where error.error == "RecordNotFound" {
            if groups.count > 1 {
                let half = groups.count / 2
                let first = try await deleteBatch(Array(groups[..<half]))
                return first + (try await deleteBatch(Array(groups[half...])))
            }
            guard writes.count > 1 else { return 0 }  // already gone
            var deleted = 0
            for write in writes { deleted += try await deleteBatch([[write]]) }
            return deleted
        }
    }
}

extension DriveSnapshot {
    /// How long history is kept (from the drive's settings).
    public var retention: TimeInterval { (settings ?? DriveSettings()).retention }

    /// The whole drive as it was at `date` (see `DriveHistory.tree(at:current:)`).
    public func tree(at date: Date) -> DriveTree { history.tree(at: date, current: tree) }

    /// What's in the trash: deleted within the retention period, newest first.
    public func trash(now: Date = Date()) -> [DriveHistory.TrashItem] {
        history.trash(current: tree, since: now - retention)
    }

    /// Changes, newest first.
    public func entries(_ scope: DriveHistory.Scope) -> [DriveHistory.Entry] {
        history.entries(scope, current: tree)
    }

    /// What current files and history take up.
    public func usage() -> DriveHistory.Usage { history.usage(current: tree) }
}

/// Works out how to put things back: where each goes (bringing back deleted folders above it,
/// with a name nothing else in its folder has), and the changes that do it, folders before
/// what's in them.
struct Restoration {
    let drive: Drive
    let history: DriveHistory
    let tree: DriveTree
    let trash: [String: DriveHistory.TrashItem]
    private let lineages: DriveHistory.Lineages
    /// Where each node will be.
    private var place: [String: (parent: String?, name: String)] = [:]
    /// Folder → name → the node that has it.
    private var taken: [String?: [String: String]] = [:]
    /// Nodes that will exist: there now (readable or not), or restored here.
    private var present: Set<String>
    private var folders: Set<String>
    private(set) var changes: [Drive.NodeChange] = []
    private(set) var skipped: [String] = []

    init(drive: Drive, snapshot: DriveSnapshot) {
        self.drive = drive
        history = snapshot.history
        tree = snapshot.tree
        lineages = DriveHistory.Lineages(snapshot.history, snapshot.tree)
        trash = Dictionary(
            snapshot.history.trash(current: snapshot.tree).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        present = Set(tree.nodes.keys).union(tree.unreadable.keys)
        folders = Set(tree.nodes.values.filter(\.isFolder).map(\.id)).union(tree.unreadable.keys)
        for node in tree.nodes.values {
            let parent = tree.parent(of: node.id)
            place[node.id] = (parent, node.name)
            taken[parent, default: [:]][node.name] = node.id
        }
    }

    func isPresent(_ id: String) -> Bool { present.contains(id) }

    /// Whether `node` will be `folder` or somewhere inside it.
    func isInside(_ node: String, _ folder: String) -> Bool {
        var cursor: String? = node
        var steps = 0
        while let id = cursor, steps <= place.count {
            if id == folder { return true }
            cursor = place[id]?.parent ?? nil
            steps += 1
        }
        return false
    }

    /// Frees the names of things about to be put back, so they don't clash with each other.
    mutating func release(_ ids: [String]) {
        for id in ids {
            guard let (parent, name) = place[id], taken[parent]?[name] == id else { continue }
            taken[parent]?[name] = nil
        }
    }

    /// The folder to put something in that was in `id`: `id`, brought back with the deleted
    /// folders above it if need be; the top level if it's gone for good.
    mutating func folder(_ id: String?) -> String? {
        guard let id else { return nil }
        if present.contains(id) { return folders.contains(id) ? id : nil }
        var chain: [DriveHistory.TrashItem] = []
        var cursor: String? = id
        while let next = cursor, !present.contains(next), let item = trash[next], item.isFolder,
            !chain.contains(where: { $0.id == next })
        {
            chain.append(item)
            cursor = item.record.parent
        }
        var parent = cursor.flatMap { folders.contains($0) ? $0 : nil }
        for item in chain.reversed() {
            restore(item.id, to: item.record, in: parent)
            parent = folders.contains(item.id) ? item.id : nil
        }
        return folders.contains(id) ? id : nil
    }

    /// Puts a node back as `target` (contents, name) in `parent`: brought back under its own ID
    /// if it's gone, or changed back if it's there.
    mutating func restore(_ id: String, to target: NodeRecord, in parent: String?) {
        if target.kind == .file, target.chunks == nil {
            skipped.append(id)  // its contents are no longer in history
            return
        }
        if tree.unreadable[id] != nil {
            skipped.append(id)
            return
        }
        var name = target.name
        if let holder = taken[parent]?[name], holder != id {
            name = ConflictName.make(for: target.name) { taken[parent]?[$0] != nil }
        }
        if let current = tree.nodes[id] {
            var record = current.record
            record.parent = parent
            record.name = name
            if record.kind == .file, record.sha256 != target.sha256 || record.size != target.size {
                record.sha256 = target.sha256
                record.size = target.size
                record.chunks = target.chunks
                record.contentsFrom = target.contentsFrom
                record.modifiedAt = target.modifiedAt
            }
            if record != current.record || place[id]?.parent != parent {
                changes.append(drive.change(.update, node: id, record: record, .restored, prev: current.record.version))
            }
        } else {
            var record = target
            record.parent = parent
            record.name = name
            let prev = lineages.of(id)?.head.id
            changes.append(drive.change(.create, node: id, record: record, .restored, prev: prev))
            present.insert(id)
            if target.kind == .folder { folders.insert(id) }
        }
        if let old = place[id], taken[old.parent]?[old.name] == id { taken[old.parent]?[old.name] = nil }
        place[id] = (parent, name)
        taken[parent, default: [:]][name] = id
    }

    /// Writes the changes, folders first.
    func commit() async throws -> Drive.RestoreResult {
        let (written, raced) = try await drive.commit(changes)
        return Drive.RestoreResult(restored: written, skipped: skipped + raced.map(\.node))
    }
}

import Foundation

/// One change to a file or folder (`VersionRecord`), as stored.
public struct Version: Sendable, Equatable, Identifiable {
    /// Record key: a TID made when the change was, so versions sort by time.
    public let id: String
    public let cid: String
    public let record: VersionRecord

    public init(id: String, cid: String, record: VersionRecord) {
        self.id = id
        self.cid = cid
        self.record = record
    }

    /// The node (file or folder) that changed.
    public var node: String { record.node }
    /// When the change was made, by the clock of the device that made it.
    public var date: Date { TID.date(id) ?? .distantPast }
}

/// A version record this device can't read (e.g. sealed with a key it doesn't have yet). It's
/// kept, so it can be read again later, and nothing here deletes it.
public struct UnreadableVersion: Sendable, Equatable {
    public let id: String
    public let cid: String
    public let reason: UnreadableNode.Reason
    /// The record as stored, to read again.
    public let value: JSONValue?
}

/// The drive's history: every version record, by node. `DriveSnapshot` keeps it current from
/// the change feed, like the tree.
///
/// **Lines and races.** Following `prev` back from a node's current version (the one its record
/// names, or, once it's deleted, its last delete) gives the line of changes that made it what it
/// is. A version that isn't on that line lost a race: another device's change, based on the
/// same version, was written over it. `ConflictRules.lostChange` says what then happens to it,
/// and `Drive.settleRaces` does it.
///
/// **The drive as of a time** is, for each node, the newest version on its line from then or
/// before: none, or a delete, means it didn't exist then.
public struct DriveHistory: Sendable {
    public private(set) var versions: [String: Version] = [:]
    public private(set) var unreadable: [String: UnreadableVersion] = [:]
    /// Node ID → its versions' IDs, oldest first.
    private var byNode: [String: [String]] = [:]

    /// Deleting one folder deletes everything in it a moment apart (`Drive.delete` stamps all
    /// the versions first). Things deleted this close before the folder count as deleted with it.
    public static let sameDeletion: TimeInterval = 1

    public init() {}

    public init(_ versions: [Version], unreadable: [UnreadableVersion] = []) {
        for version in versions { insert(version) }
        for record in unreadable { self.unreadable[record.id] = record }
    }

    // MARK: Storage

    /// Adds or replaces a stored version record, as `Drive.readVersion` read it. One it couldn't
    /// read is kept as unreadable.
    mutating func set(_ entry: VersionEntry) {
        remove(entry.id)
        switch entry {
        case .readable(let version): insert(version)
        case .unreadable(let record): unreadable[record.id] = record
        }
    }

    /// Reads the unreadable records again (with `Drive.readVersion`), e.g. once a key arrives.
    mutating func reread(_ read: (String, String, JSONValue?) -> VersionEntry) {
        for record in unreadable.values { set(read(record.id, record.cid, record.value)) }
    }

    private mutating func insert(_ version: Version) {
        versions[version.id] = version
        let index = Self.insertionIndex(of: version.id, in: byNode[version.node] ?? [])
        byNode[version.node, default: []].insert(version.id, at: index)
    }

    /// Forgets a version record (it was deleted).
    mutating func remove(_ id: String) {
        unreadable[id] = nil
        guard let old = versions.removeValue(forKey: id) else { return }
        byNode[old.node]?.removeAll { $0 == id }
        if byNode[old.node]?.isEmpty == true { byNode[old.node] = nil }
    }

    /// Where `id` goes in ascending `sorted`: after every ID at or below it.
    private static func insertionIndex(of id: String, in sorted: [String]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] <= id { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Looking things up

    public func version(_ id: String) -> Version? { versions[id] }

    /// A node's versions, oldest first.
    public func versions(of node: String) -> [Version] { (byNode[node] ?? []).compactMap { versions[$0] } }

    /// Every node with history (current, in the trash, or deleted for good).
    public var nodeIDs: Dictionary<String, [String]>.Keys { byNode.keys }

    /// The version holding a version's chunks: itself, or the one it points to.
    func contentsHolder(of version: Version) -> Version? {
        if version.record.chunks != nil { return version }
        guard let from = version.record.contentsFrom, let holder = versions[from], holder.record.chunks != nil
        else { return nil }
        return holder
    }

    /// The node as a version left it, chunks included (from wherever they're kept), and with its
    /// `version` and `contentsFrom` filled in. `nil` for a delete. A file whose chunks are no
    /// longer in history has none (`contentsAvailable`).
    public func record(at version: Version) -> NodeRecord? {
        guard var state = version.record.state else { return nil }
        state.version = version.id
        if state.kind == .file {
            let holder = contentsHolder(of: version)
            state.chunks = holder?.record.chunks
            state.contentsFrom = holder?.id ?? version.record.contentsFrom
            state.continuations = holder?.record.continuations
        }
        return state
    }

    /// Whether a version's contents can still be read: always for a folder, and for a file as
    /// long as the version holding its chunks is kept.
    public func contentsAvailable(_ version: Version) -> Bool {
        version.record.kind != .file || contentsHolder(of: version) != nil
    }

    // MARK: Lines of changes

    /// How a node's versions connect (see the type's comment).
    struct Lineage {
        /// The node's current version, or, when it's deleted, the delete.
        let head: Version
        /// From `head` back along `prev`, newest first.
        let line: [Version]
        let onLine: Set<String>
        /// The line's IDs, oldest first.
        let sortedLine: [String]
        /// Whether the line goes back to the node's first version, rather than to one that was
        /// pruned.
        let complete: Bool
    }

    /// The line of changes behind a node, given what the drive holds now. `nil` when that can't
    /// be told: the node can't be read here, its record names no version (written before there
    /// was history), or it's gone without a delete in its history.
    func lineage(of node: String, in current: DriveTree) -> Lineage? {
        guard current.unreadable[node] == nil, let ids = byNode[node], !ids.isEmpty else { return nil }
        let head: Version
        if let existing = current.nodes[node] {
            guard let id = existing.record.version, let version = versions[id], version.node == node else {
                return nil
            }
            head = version
        } else {
            // Deleted: its last delete, which no version follows.
            let followed = Set(ids.compactMap { versions[$0]?.record.prev })
            guard let id = ids.last(where: { versions[$0]?.record.isDeletion == true && !followed.contains($0) })
            else { return nil }
            head = versions[id]!
        }
        var line: [Version] = []
        var onLine: Set<String> = []
        var complete = false
        var cursor: Version? = head
        while let version = cursor, version.node == node, onLine.insert(version.id).inserted {
            line.append(version)
            guard let prev = version.record.prev else {
                complete = true
                break
            }
            cursor = versions[prev]
        }
        return Lineage(head: head, line: line, onLine: onLine, sortedLine: onLine.sorted(), complete: complete)
    }

    /// Lineages, worked out once each for one query.
    final class Lineages {
        let history: DriveHistory
        let current: DriveTree
        private var known: [String: Lineage?] = [:]

        init(_ history: DriveHistory, _ current: DriveTree) {
            self.history = history
            self.current = current
        }

        func of(_ node: String) -> Lineage? {
            if let lineage = known[node] { return lineage }
            let lineage = history.lineage(of: node, in: current)
            known[node] = .some(lineage)
            return lineage
        }
    }

    /// The version that says what a node was like at `bound` (a TID): the newest on its line at
    /// or before it (before it, unless `inclusive`). Without a line, the newest of all.
    func version(of node: String, upTo bound: String, inclusive: Bool, lineages: Lineages) -> Version? {
        let ids = lineages.of(node)?.sortedLine ?? byNode[node] ?? []
        var low = 0
        var high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if inclusive ? ids[middle] <= bound : ids[middle] < bound { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? versions[ids[low - 1]] : nil
    }

    /// The node as it was at `bound`, or `nil` if it didn't exist then. A node with no history
    /// at all (written before there was any) is taken as it is now.
    func record(of node: String, upTo bound: String, inclusive: Bool, lineages: Lineages) -> NodeRecord? {
        if byNode[node] == nil { return lineages.current.nodes[node]?.record }
        return version(of: node, upTo: bound, inclusive: inclusive, lineages: lineages).flatMap(record(at:))
    }

    /// Where something named `name` in `parent` was at `bound`, and the folders it was in
    /// (innermost first). Folders that didn't exist then end the path there, as in a tree.
    func path(
        name: String, parent: String?, upTo bound: String, inclusive: Bool, lineages: Lineages
    ) -> (path: DrivePath, folders: [String]) {
        var components = [name]
        var folders: [String] = []
        var cursor = parent
        while let id = cursor, !folders.contains(id), folders.count < 4096,
            let folder = record(of: id, upTo: bound, inclusive: inclusive, lineages: lineages),
            folder.kind == .folder
        {
            components.append(folder.name)
            folders.append(id)
            cursor = folder.parent
        }
        return (DrivePath(components: components.reversed()), folders)
    }

    // MARK: The drive as it was

    /// The whole drive as it was at `date`: each node as its newest version from then or
    /// before left it. Paths can be looked up in it as usual, as of then.
    public func tree(at date: Date, current: DriveTree) -> DriveTree {
        let bound = TID.highest(at: date)
        let lineages = Lineages(self, current)
        var nodes: [Node] = []
        for node in byNode.keys {
            guard let version = version(of: node, upTo: bound, inclusive: true, lineages: lineages),
                let record = record(at: version)
            else { continue }
            nodes.append(Node(id: node, cid: version.cid, record: record))
        }
        // Nothing in history: written before there was any. As it is now, if it existed then.
        for node in current.nodes.values where byNode[node.id] == nil {
            if let created = node.record.createdDate, created > date { continue }
            nodes.append(node)
        }
        return DriveTree(nodes)
    }

    /// The node as it was at `date`, if it existed then.
    public func node(_ id: String, at date: Date, current: DriveTree) -> Node? {
        let lineages = Lineages(self, current)
        guard let version = version(of: id, upTo: TID.highest(at: date), inclusive: true, lineages: lineages),
            let record = record(at: version)
        else { return byNode[id] == nil ? current.nodes[id] : nil }
        return Node(id: id, cid: version.cid, record: record)
    }

    /// The version before a node's current one, on its line: what undoing its latest change
    /// goes back to. `nil` if there's none (just created, or history pruned).
    public func previousVersion(of node: String, current: DriveTree) -> Version? {
        guard let lineage = lineage(of: node, in: current), lineage.line.count > 1 else { return nil }
        return lineage.line[1]
    }

    // MARK: The trash

    /// Something deleted that history can still bring back.
    public struct TrashItem: Sendable, Equatable, Identifiable {
        /// The node's ID: restoring it brings it back under this ID.
        public var id: String
        /// The delete.
        public var deletion: Version
        /// The version it was deleted from: what restoring it brings back.
        public var before: Version
        /// It as `before` left it.
        public var record: NodeRecord
        /// Where it was, just before it was deleted.
        public var path: DrivePath
        /// Deleted along with the folder it was in: restoring the folder brings it back too.
        public var deletedWithFolder: Bool

        public var name: String { record.name }
        public var isFolder: Bool { record.kind == .folder }
        public var deletedAt: Date { deletion.date }
    }

    /// Everything in the trash: the nodes whose latest change is a delete, newest delete first.
    /// Pass `since` for the retention period (`now - settings.retention`); deletes older than
    /// that are on their way out (`Drive.prune`).
    public func trash(current: DriveTree, since: Date? = nil) -> [TrashItem] {
        let lineages = Lineages(self, current)
        let earliest = since.map(TID.lowest(at:))
        var found: [String: (deletion: Version, before: Version, record: NodeRecord)] = [:]
        for node in byNode.keys where current.nodes[node] == nil {
            guard let lineage = lineages.of(node), lineage.head.record.isDeletion, lineage.line.count > 1,
                earliest.map({ lineage.head.id >= $0 }) ?? true, let record = record(at: lineage.line[1])
            else { continue }
            found[node] = (lineage.head, lineage.line[1], record)
        }
        return found.map { node, item in
            let place = path(
                name: item.record.name, parent: item.record.parent, upTo: item.deletion.id, inclusive: false,
                lineages: lineages)
            var withFolder = false
            if let parent = item.record.parent, let folder = found[parent] {
                let gap = folder.deletion.date.timeIntervalSince(item.deletion.date)
                withFolder = folder.deletion.id > item.deletion.id && gap <= Self.sameDeletion
            }
            return TrashItem(
                id: node, deletion: item.deletion, before: item.before, record: item.record, path: place.path,
                deletedWithFolder: withFolder)
        }.sorted { $0.deletion.id > $1.deletion.id }
    }

    /// A trash item and everything deleted with it (for a folder: what was in it), parents
    /// before what's inside them.
    func deletedTogether(_ id: String, trash: [String: TrashItem]) -> [TrashItem] {
        guard let top = trash[id] else { return [] }
        var inside: [String: [TrashItem]] = [:]
        for item in trash.values where item.deletedWithFolder {
            if let parent = item.record.parent { inside[parent, default: []].append(item) }
        }
        var result: [TrashItem] = []
        var queue = [top]
        var index = 0
        var seen: Set<String> = [id]
        while index < queue.count {
            let item = queue[index]
            index += 1
            result.append(item)
            for child in (inside[item.id] ?? []).sorted(by: { $0.id < $1.id }) where seen.insert(child.id).inserted {
                queue.append(child)
            }
        }
        return result
    }

    // MARK: Listing history

    /// One change, for a history listing.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var version: Version
        /// The node as the change left it; for a delete, as it was just before. `nil` if that's
        /// no longer in history.
        public var record: NodeRecord?
        /// Where it was then: after the change, or for a delete, just before it.
        public var path: DrivePath?
        /// It lost a race: another device's change, based on the same version, was written over
        /// it. It's kept in history; `Drive.settleRaces` decides what else happens to it.
        public var lost: Bool

        public var id: String { version.id }
        public var node: String { version.node }
        public var change: VersionRecord.Change { version.record.change }
        public var date: Date { version.date }
        public var device: String { version.record.device }
        public var name: String? { record?.name }
    }

    public enum Scope: Sendable, Equatable {
        /// Every change in the drive.
        case drive
        /// Changes to one file or folder.
        case node(String)
        /// Changes to a folder and to everything that was in it at the time.
        case folder(String)
    }

    /// Changes, newest first.
    public func entries(_ scope: Scope, current: DriveTree) -> [Entry] {
        let lineages = Lineages(self, current)
        let candidates: [Version]
        if case .node(let node) = scope {
            candidates = versions(of: node)
        } else {
            candidates = Array(versions.values)
        }
        var entries: [Entry] = []
        for version in candidates {
            let lineage = lineages.of(version.node)
            var record: NodeRecord?
            var inclusive = true
            if version.record.isDeletion {
                record = version.record.prev.flatMap { versions[$0] }.flatMap(self.record(at:))
                inclusive = false
            } else {
                record = self.record(at: version)
            }
            let place = record.map {
                path(name: $0.name, parent: $0.parent, upTo: version.id, inclusive: inclusive, lineages: lineages)
            }
            if case .folder(let folder) = scope, version.node != folder,
                !(place?.folders.contains(folder) ?? false)
            {
                continue
            }
            entries.append(
                Entry(
                    version: version, record: record, path: place?.path,
                    lost: lineage.map { !$0.onLine.contains(version.id) } ?? false))
        }
        return entries.sorted { $0.version.id > $1.version.id }
    }

    // MARK: Space

    /// What the drive's chunks take up, each counted once however many files and versions
    /// share it.
    public struct Usage: Sendable, Equatable {
        /// Bytes of the chunks current files use.
        public var current: Int
        /// Bytes of the chunks only history uses: older versions, and the trash.
        public var historyOnly: Int
        public var currentChunks: Int
        public var historyOnlyChunks: Int
        /// Bytes of the chunks current files use that history uses too: what history costs
        /// nothing extra for.
        public var shared: Int
        public var sharedChunks: Int

        public var total: Int { current + historyOnly }
    }

    public func usage(current: DriveTree) -> Usage {
        var now: [String: Int] = [:]
        for node in current.nodes.values {
            for chunk in node.record.chunks ?? [] { now[chunk.cid] = chunk.size }
        }
        var past: [String: Int] = [:]
        var shared: [String: Int] = [:]
        for version in versions.values {
            for chunk in version.record.chunks ?? [] {
                if let size = now[chunk.cid] { shared[chunk.cid] = size } else { past[chunk.cid] = chunk.size }
            }
        }
        return Usage(
            current: now.values.reduce(0, +), historyOnly: past.values.reduce(0, +), currentChunks: now.count,
            historyOnlyChunks: past.count, shared: shared.values.reduce(0, +), sharedChunks: shared.count)
    }

    // MARK: Pruning

    /// The versions pruning at `cutoff` deletes, oldest first: those from before it, except
    /// what's needed to know each node's state when the window starts (its newest version on
    /// its line from before then) and anything a kept version takes its contents from. A node
    /// deleted before the window, with nothing of it after, loses every version. Unreadable
    /// versions, and ones whose key isn't a TID, are never pruned. Nor is the version a current
    /// file takes its contents from: a long chunk list is only in that version's `chunks`
    /// records, so they're what keeps the file's chunks.
    func pruneable(current: DriveTree, cutoff: Date) -> [String] {
        let cutoffID = TID.lowest(at: cutoff)
        let lineages = Lineages(self, current)
        var doomed: Set<String> = []
        for (node, ids) in byNode {
            let old = ids.filter { $0 < cutoffID && TID.date($0) != nil }
            guard !old.isEmpty else { continue }
            let lineage = lineages.of(node)
            let gone = current.nodes[node] == nil && current.unreadable[node] == nil
            if gone, let lineage, lineage.head.record.isDeletion, old.count == ids.count {
                doomed.formUnion(old)
                continue
            }
            let anchor = (lineage?.sortedLine ?? ids).last { $0 < cutoffID }
            doomed.formUnion(old.filter { $0 != anchor })
        }
        for version in versions.values where !doomed.contains(version.id) {
            if let from = version.record.contentsFrom { doomed.remove(from) }
        }
        for node in current.nodes.values {
            if let from = node.record.contentsFrom { doomed.remove(from) }
        }
        return doomed.sorted()
    }

    // MARK: Races

    /// A change that lost a race: the newest version of a branch off a node's line.
    struct Race {
        let node: String
        let lost: Version
        /// The version on the line it branched from; `nil` if both started from nothing.
        let fork: Version?
        let lineage: Lineage
        /// Its contents are already on the line since the fork (a race settled before).
        let absorbed: Bool
    }

    /// The races in the drive's history whose losing change is from `since` (a TID) or later.
    /// Older ones are history on its way out (`pruneable`).
    func races(current: DriveTree, since: String?) -> [Race] {
        var races: [Race] = []
        for (node, ids) in byNode where ids.count > 1 {
            // Only a version two others are based on (or two first versions) makes a race.
            var children: [String: Int] = [:]
            var firsts = 0
            for id in ids {
                if let prev = versions[id]?.record.prev { children[prev, default: 0] += 1 } else { firsts += 1 }
            }
            guard firsts > 1 || children.values.contains(where: { $0 > 1 }),
                let lineage = lineage(of: node, in: current)
            else { continue }
            for tip in ids where children[tip] == nil && !lineage.onLine.contains(tip) {
                if let since, tip < since { continue }
                let lost = versions[tip]!
                // Back along its branch to the line.
                var fork: Version?
                var connected = false
                var cursor = lost.record.prev
                var seen: Set<String> = []
                while true {
                    guard let id = cursor else {
                        connected = lineage.complete
                        break
                    }
                    guard seen.insert(id).inserted, let version = versions[id], version.node == node else { break }
                    if lineage.onLine.contains(id) {
                        fork = version
                        connected = true
                        break
                    }
                    cursor = version.record.prev
                }
                guard connected else { continue }  // it branched from history that's been pruned
                let since = fork.flatMap { fork in lineage.line.firstIndex { $0.id == fork.id } } ?? lineage.line.count
                let absorbed =
                    lost.record.state.map { state in
                        lineage.line[..<since].contains {
                            $0.record.kind == state.kind && !$0.record.isDeletion && $0.record.sha256 == state.sha256
                        }
                    } ?? false
                races.append(Race(node: node, lost: lost, fork: fork, lineage: lineage, absorbed: absorbed))
            }
        }
        return races.sorted { $0.lost.id < $1.lost.id }
    }
}

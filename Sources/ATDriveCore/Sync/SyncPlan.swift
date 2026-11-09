import Foundation

/// A file or folder as one side of the sync (the folder, the drive, or the last sync) sees it.
/// Everything is keyed by node ID; a thing only the folder has gets a temporary ID, `+<path>`
/// (record keys never contain `+`).
struct SyncEntry: Equatable {
    struct Location: Hashable {
        var parent: String?
        var name: String
    }

    var parent: String?
    var name: String
    var isFolder: Bool
    /// Files only.
    var sha256: String?

    var location: Location {
        get { Location(parent: parent, name: name) }
        set { (parent, name) = (newValue.parent, newValue.name) }
    }

    func at(_ location: Location) -> SyncEntry {
        var copy = self
        copy.location = location
        return copy
    }

    func with(sha256: String?) -> SyncEntry {
        var copy = self
        copy.sha256 = sha256
        return copy
    }
}

func temporaryID(_ path: String) -> String { "+" + path }

/// The last sync's view, with each item's path in the folder.
struct SyncBase {
    let items: [String: SyncState.Item]
    let entries: [String: SyncEntry]
    let paths: [String: String]

    /// Keeps only items whose folders are all known (anything else is treated as new on both
    /// sides, and matched up again by path and contents).
    init(_ saved: [String: SyncState.Item]) {
        var paths: [String: String?] = [:]
        func path(_ id: String, depth: Int = 0) -> String? {
            if let known = paths[id] { return known }
            guard depth < 4096, let item = saved[id] else { return nil }
            var result: String? = item.name
            if let parent = item.parent {
                result =
                    saved[parent]?.folder == true ? path(parent, depth: depth + 1).map { "\($0)/\(item.name)" } : nil
            }
            if let found = result, SyncIgnore.isIgnored(path: found.split(separator: "/").map(String.init)) {
                result = nil
            }
            paths[id] = .some(result)
            return result
        }
        var kept: [String: String] = [:]
        for id in saved.keys {
            if let found = path(id) { kept[id] = found }
        }
        items = saved.filter { kept[$0.key] != nil }
        entries = items.mapValues {
            SyncEntry(parent: $0.parent, name: $0.name, isFolder: $0.folder, sha256: $0.folder ? nil : $0.sha256)
        }
        self.paths = kept
    }
}

/// The folder now, keyed like the last sync: things still at their old path keep their ID, and
/// so do things that moved (found by inode, or by contents for files copied and deleted).
struct LocalView {
    var entries: [String: SyncEntry] = [:]
    /// Path in the folder, by ID.
    var paths: [String: String] = [:]
    var stats: [String: FileStat] = [:]
    /// Present, but not to be touched or trusted this time: being written, or unreadable.
    /// Their contents count as unchanged.
    var frozen: Set<String> = []
    /// Whether some file was too recently written to sync yet.
    var waiting = false
    var skipped: [String] = []
    /// Every folder (absolute paths), for the watcher.
    var folders: [String] = []

    init(scan: FolderScan, base: SyncBase, root: String, now: Date = Date(), settle: TimeInterval) {
        skipped = scan.skipped
        folders = [root] + scan.items.filter(\.value.isFolder).keys.map { "\(root)/\($0)" }
        let byPath = Dictionary(base.paths.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var idAt: [String: String] = [:]
        for (path, item) in scan.items {
            if let id = byPath[path], base.items[id]?.folder == item.isFolder { idAt[path] = id }
        }
        var missing = Set(base.items.keys).subtracting(idAt.values)

        // Renamed or moved: same inode (and, for files, unchanged).
        struct Inode: Hashable {
            var device: UInt64
            var inode: UInt64
        }
        var byInode: [Inode: String] = [:]
        for id in missing {
            let stat = base.items[id]!.stat
            byInode[Inode(device: stat.device, inode: stat.inode)] = id
        }
        for (path, item) in scan.items.sorted(by: { $0.key < $1.key }) where idAt[path] == nil {
            let key = Inode(device: item.stat.device, inode: item.stat.inode)
            guard let id = byInode[key], let saved = base.items[id], saved.folder == item.isFolder else { continue }
            if !item.isFolder, saved.stat.size != item.stat.size || saved.stat.modified != item.stat.modified {
                continue
            }
            idAt[path] = id
            missing.remove(id)
            byInode[key] = nil
        }

        // Inside a folder that couldn't be read: assume nothing changed rather than that it's gone.
        for id in missing {
            let path = base.paths[id]!
            guard scan.unreadable.contains(where: { path != $0 && path.isWithin($0) }) else { continue }
            let saved = base.items[id]!
            idAt[path] = id
            entries[id] = base.entries[id]
            paths[id] = path
            stats[id] = saved.stat
            frozen.insert(id)
            missing.remove(id)
        }

        // Contents: unchanged files keep their hash; others are read, unless still being written.
        var hashes: [String: String] = [:]
        let nowNanos = Int64(now.timeIntervalSince1970 * 1_000_000_000)
        let settleNanos = Int64(settle * 1_000_000_000)
        for (path, item) in scan.items where !item.isFolder {
            let saved = idAt[path].flatMap { base.items[$0] }
            if let saved, saved.stat == item.stat {
                hashes[path] = saved.sha256
                continue
            }
            let age = nowNanos - item.stat.changed
            var hash: String?
            if age >= settleNanos || age < -settleNanos {
                hash = try? LocalFS.sha256("\(root)/\(path)")
            } else {
                waiting = true
            }
            if let hash {
                hashes[path] = hash
            } else if let id = idAt[path], let saved {
                hashes[path] = saved.sha256
                frozen.insert(id)
            }
        }

        // Copied somewhere and deleted (e.g. moved across disks): same contents.
        var bySHA: [String: String] = [:]
        for id in missing.sorted() {
            if let saved = base.items[id], !saved.folder, let sha = saved.sha256 { bySHA[sha] = id }
        }
        for (path, item) in scan.items.sorted(by: { $0.key < $1.key }) where !item.isFolder && idAt[path] == nil {
            guard let sha = hashes[path], let id = bySHA[sha] else { continue }
            idAt[path] = id
            bySHA[sha] = nil
        }

        for (path, item) in scan.items {
            if !item.isFolder, hashes[path] == nil { continue }  // new and not ready yet
            let id = idAt[path] ?? temporaryID(path)
            let parentPath = path.parentPath
            entries[id] = SyncEntry(
                parent: parentPath.isEmpty ? nil : idAt[parentPath] ?? temporaryID(parentPath),
                name: String(path.split(separator: "/").last!), isFolder: item.isFolder,
                sha256: item.isFolder ? nil : hashes[path])
            paths[id] = path
            stats[id] = item.stat
        }
    }

    /// Whether anything differs from the last sync (so the drive should be checked before
    /// pushing changes).
    func differs(from base: SyncBase) -> Bool {
        entries.count != base.entries.count || entries.contains { base.entries[$0.key] != $0.value }
    }
}

/// The drive now, minus anything ignored.
struct RemoteView {
    let tree: DriveTree
    let entries: [String: SyncEntry]

    init(_ tree: DriveTree) {
        self.tree = tree
        var entries: [String: SyncEntry] = [:]
        for node in tree.nodes.values where !SyncIgnore.isIgnored(path: tree.path(of: node).components) {
            entries[node.id] = SyncEntry(
                parent: tree.parent(of: node.id), name: node.name, isFolder: node.isFolder,
                sha256: node.isFolder ? nil : node.record.sha256)
        }
        self.entries = entries
    }
}

/// What the folder and the drive should both look like after this sync, worked out from the
/// last sync's view and each side's changes since, by `ConflictRules` (the same rules the Mac
/// app follows). Per item, it asks those rules about contents, location and deletions; across
/// items, it keeps folders that something kept is in, and gives each name in a folder to one
/// item (the one already on the drive; identical ones are paired up).
struct SyncPlan {
    /// By node ID, or a temporary ID for things the drive doesn't have yet.
    var merged: [String: SyncEntry] = [:]
    /// Which file or folder in the folder (by local ID) becomes each merged item. Missing for
    /// things to download or create here.
    var localSource: [String: String] = [:]
    /// Conflicted copies (merged ID) → the item they were split from. The local file keeps
    /// its place until the drive's version is downloaded, then becomes the copy.
    var splitFrom: [String: String] = [:]
    /// Renamed because of a name clash (merged ID → name before).
    var renamed: [String: String] = [:]

    init(base: [String: SyncEntry], local: LocalView, remote: [String: SyncEntry]) {
        var candidates: [String: (entry: SyncEntry, local: Bool)] = [:]
        var remap: [String: String] = [:]
        // A fresh ID for something that has to be created again on the drive.
        func renewed(_ id: String) -> String { temporaryID(local.paths[id]!) }

        for id in Set(base.keys).union(local.entries.keys).union(remote.keys).sorted() {
            switch (base[id], local.entries[id], remote[id]) {
            case (nil, let here?, _):
                add(id, here, from: id)
            case (nil, nil, let there?):
                add(id, there)
            case (_, nil, nil):
                continue
            case (let before?, let here?, nil):  // deleted from the drive
                if here.isFolder {
                    candidates[id] = (here, true)
                } else if !ConflictRules.deleteStands(base: before.sha256, other: here.sha256) {
                    add(renewed(id), here, from: id)  // edited here: kept
                }
            case (let before?, nil, let there?):  // deleted here
                if there.isFolder {
                    candidates[id] = (there, false)
                } else if !ConflictRules.deleteStands(base: before.sha256, other: there.sha256) {
                    add(id, there)  // edited on the drive: kept
                }
            case (let before?, let here?, let there?):
                let location = ConflictRules.location(
                    base: before.location, local: here.location, remote: there.location)
                switch ConflictRules.contents(base: before.sha256, local: here.sha256, remote: there.sha256) {
                case .local:
                    add(id, here.at(location), from: id)
                case .remote:
                    add(id, here.at(location).with(sha256: there.sha256), from: id)
                case .conflict:
                    add(id, there.at(location))
                    let copy = renewed(id)
                    add(copy, here.at(location), from: id)  // renamed below: it clashes with `id`
                    splitFrom[copy] = id
                }
            }
        }

        // Folders deleted on one side survive if something that survives is inside them.
        var changed = true
        while changed {
            changed = false
            let needed = Set(merged.values.compactMap(\.parent))
            for (id, candidate) in candidates.sorted(by: { $0.key < $1.key }) where needed.contains(id) {
                candidates[id] = nil
                changed = true
                if candidate.local {  // gone from the drive: create it again
                    let fresh = renewed(id)
                    add(fresh, candidate.entry, from: id)
                    remap[id] = fresh
                } else {
                    add(id, candidate.entry)
                }
            }
        }
        for (id, entry) in merged {
            if let parent = entry.parent, let fresh = remap[parent] { merged[id]!.parent = fresh }
        }
        for (id, entry) in merged {
            if let parent = entry.parent, merged[parent]?.isFolder != true { merged[id]!.parent = nil }
        }

        // Moves on both sides can make a folder end up inside itself: lift one to the top.
        for id in merged.keys.sorted() {
            var seen: Set<String> = [id]
            var current = merged[id]?.parent
            while let folder = current {
                if !seen.insert(folder).inserted {
                    merged[folder]!.parent = nil
                    break
                }
                current = merged[folder]?.parent
            }
        }

        resolveNameClashes(local: local, remote: remote)
    }

    private mutating func add(_ id: String, _ entry: SyncEntry, from localID: String? = nil) {
        merged[id] = entry
        if let localID { localSource[id] = localID }
    }

    /// One name per folder: top-down, so folders matched up are merged before their contents.
    private mutating func resolveNameClashes(local: LocalView, remote: [String: SyncEntry]) {
        var children: [String?: [String]] = [:]
        for (id, entry) in merged { children[entry.parent, default: []].append(id) }

        func isOnDrive(_ id: String) -> Bool { remote[id]?.location == merged[id]?.location }
        func isHere(_ id: String) -> Bool {
            guard splitFrom[id] == nil, let localID = localSource[id], let here = local.entries[localID],
                let entry = merged[id]
            else { return false }
            return here.name == entry.name && here.parent == entry.parent.flatMap { localSource[$0] }
        }
        // `other`, which is only here, is the same thing as `keeper`, which is only on the drive.
        func isSame(_ other: String, as keeper: String) -> Bool {
            guard let a = merged[other], let b = merged[keeper], localSource[keeper] == nil, remote[keeper] != nil,
                remote[other] == nil, localSource[other] != nil, a.isFolder == b.isFolder
            else { return false }
            return a.isFolder || a.sha256 == b.sha256
        }

        var queue: [String?] = [nil]
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            let groups = Dictionary(grouping: children[folder] ?? [], by: { merged[$0]!.name })
            for (name, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
                func score(_ id: String) -> Int { (isOnDrive(id) ? 2 : 0) + (isHere(id) ? 1 : 0) }
                let ordered = group.sorted { score($0) != score($1) ? score($0) > score($1) : $0 < $1 }
                for other in ordered.dropFirst() {
                    let siblings = children[folder] ?? []
                    if isSame(other, as: ordered[0]) {
                        merge(other, into: ordered[0], in: folder, children: &children)
                    } else if let twin = siblings.first(where: {
                        $0 != other && !merged[$0]!.isFolder && merged[$0]!.sha256 == merged[other]!.sha256
                            && isSame(other, as: $0)
                    }) {
                        // Already on the drive under another name (e.g. a conflicted copy sent
                        // last time, before the sync was interrupted).
                        merge(other, into: twin, in: folder, children: &children)
                    } else {
                        let taken = Set(siblings.map { merged[$0]!.name })
                        renamed[other] = name
                        merged[other]!.name = ConflictName.make(for: name) { taken.contains($0) }
                    }
                }
            }
            queue += (children[folder] ?? []).filter { merged[$0]?.isFolder == true }
        }
    }

    /// `other` (only here) and `keeper` (only on the drive) are the same: the local one becomes
    /// the keeper, and anything inside it moves into the keeper.
    private mutating func merge(
        _ other: String, into keeper: String, in folder: String?, children: inout [String?: [String]]
    ) {
        localSource[keeper] = localSource.removeValue(forKey: other)
        if let original = splitFrom.removeValue(forKey: other) { splitFrom[keeper] = original }
        for child in children.removeValue(forKey: other) ?? [] {
            merged[child]!.parent = keeper
            children[keeper, default: []].append(child)
        }
        children[folder]?.removeAll { $0 == other }
        merged[other] = nil
    }
}

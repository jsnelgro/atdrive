import Foundation

/// Two-way sync between a local folder and the drive, like a Dropbox folder.
///
/// Each call to `sync()` is one pass: list the folder (cheap: `lstat` only, files are read only
/// when they look changed), fetch what changed on the drive since last time (one small request
/// when nothing did; see `Drive.update`), work out what changed on each side since the last
/// pass (`SyncPlan`), and apply that. Nothing is pushed without checking the drive first, and
/// nothing local is overwritten or deleted if it changed after the folder was listed: that's
/// left for the next pass.
///
/// What the last pass agreed on is saved in `.atdrive/state.json` inside the folder, so a pass
/// can tell "deleted here" from "new on the drive". Deleting that folder (or syncing into a new
/// one) starts over by merging: matching things are paired up and nothing is deleted. The drive
/// as last fetched is saved beside it (`drive.json`), to carry on from after a restart.
///
/// Two things are never taken for deletions on the drive: records this device can't read (left
/// alone on both sides, and reported), and a drive that's gone (syncing stops, as it does when
/// the folder disappears).
///
/// Not thread-safe: use it from one task.
public final class FolderSync {
    public let root: String
    public private(set) var drive: Drive
    /// Files changed more recently than this are left for the next pass (still being written).
    public let settle: TimeInterval

    private let folder: StateFolder
    private let log: @Sendable (SyncEvent) -> Void
    /// Skips already reported, so a file that can't be synced isn't reported on every pass.
    private var reported: Set<String> = []
    private var state: SyncState
    private var lockDescriptor: Int32
    /// The drive as last fetched.
    private var remote: DriveSnapshot?
    /// Whether this process wrote to the drive since `remote` was fetched: it's brought up to
    /// date before it's trusted again.
    private var remoteIsStale = false
    /// When `remote` was last saved, and at what revision. Saving rewrites the whole tree, so
    /// it's done at most once a minute (any saved snapshot is a consistent one to resume from).
    private var saved: (at: Date, revision: String?)?

    public struct Result: Sendable {
        /// How many things were uploaded, downloaded, moved, deleted or renamed.
        public var changes: Int
        /// Whether the drive was checked for changes this time.
        public var checkedRemote: Bool
        /// Whether some files were left for later because they're still being written.
        public var waiting: Bool
        /// Every folder (absolute paths), for a `FolderWatcher`.
        public var folders: [String]
    }

    /// Opens a folder for syncing with the drive, creating it if needed. Throws if it's synced
    /// with another account's drive or another `atdrive sync` is already syncing it.
    public init(
        folder url: URL, drive: Drive, settle: TimeInterval = 2,
        log: @escaping @Sendable (SyncEvent) -> Void = { _ in }
    ) throws {
        let path = url.standardizedFileURL.path
        if !LocalFS.exists(path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard LocalFS.isFolder(root) else { throw SyncError.notAFolder(path) }
        self.drive = drive
        self.settle = settle
        self.log = log
        folder = StateFolder(root: root)
        if !LocalFS.makeFolder(folder.path) { throw SyncError.notAFolder(folder.path) }
        lockDescriptor = try folder.lock()
        do {
            if let saved = try folder.load() {
                guard saved.owner == drive.owner, saved.space == drive.space else {
                    throw SyncError.otherAccount(folder: root, owner: saved.owner)
                }
                state = saved
            } else {
                state = SyncState(owner: drive.owner, space: drive.space)
                try folder.save(state)
            }
        } catch {
            close(lockDescriptor)
            throw error
        }
        // A head start for the first pass, which still brings it up to date before using it:
        // it may predate this folder's last writes.
        remote = folder.loadSnapshot(drive: drive)
        remoteIsStale = true
    }

    deinit { close(lockDescriptor) }

    /// Switches to a new session for the same account (after signing in again).
    public func use(_ drive: Drive) throws {
        guard drive.owner == state.owner, drive.space == state.space else {
            throw SyncError.otherAccount(folder: root, owner: state.owner)
        }
        self.drive = drive
    }

    /// One pass. `checkRemote: false` skips checking the drive unless something changed here
    /// (use it when woken by a local change, between regular checks of the drive).
    @discardableResult
    public func sync(checkRemote: Bool = true) async throws -> Result {
        guard LocalFS.isFolder(root) else { throw SyncError.folderMissing(root) }
        guard LocalFS.exists(folder.stateFile) else { throw SyncError.stateMissing(root) }
        recoverStaging()
        try? FileManager.default.removeItem(atPath: folder.downloads)

        let base = SyncBase(state.items)
        let local = LocalView(scan: try FolderScan(root: root), base: base, root: root, settle: settle)
        for path in local.skipped { report(SyncEvent(.skipped, "/" + path, "not a regular file or folder")) }
        var checked = false
        if checkRemote || remote == nil || remoteIsStale || local.differs(from: base) {
            let updated = try await drive.update(remote)
            let now = Date()
            if updated.listedAt != remote?.listedAt
                || (updated.revision != saved?.revision && now.timeIntervalSince(saved?.at ?? .distantPast) >= 60)
            {
                folder.saveSnapshot(updated)
                saved = (now, updated.revision)
            }
            remote = updated
            remoteIsStale = false
            checked = true
        }
        let snapshot = remote!
        // Gone (say the server was wiped) isn't empty: the folder may be the only copy left.
        if snapshot.revision == nil, !state.items.isEmpty { throw SyncError.driveMissing(root) }
        let view = RemoteView(snapshot.tree, base: base)
        reportUnknown(view, base: base)
        let plan = SyncPlan(base: base.entries, local: local, remote: view.entries, unknown: view.unknown)
        let run = SyncRun(
            plan: plan, base: base, local: local, remote: view, root: root, folder: folder, drive: drive
        ) { [unowned self] in self.report($0) }
        var failure: Error?
        do {
            try run.arrangeFolder()
            try await run.updateDrive()
            try await run.download()
        } catch {
            failure = error
        }
        if run.wroteRemote { remoteIsStale = true }
        let items = run.agreedItems()
        if items != state.items {
            state.items = items
            try folder.save(state)
        }
        if let failure { throw failure }
        return Result(changes: run.changes, checkedRemote: checked, waiting: local.waiting, folders: local.folders)
    }

    private func report(_ event: SyncEvent) {
        if event.kind == .skipped || event.kind == .unreadable, !reported.insert(event.description).inserted {
            return
        }
        log(event)
    }

    /// Says (once) what on the drive this device can't read: things synced before by where
    /// they are here, and the rest by record key.
    private func reportUnknown(_ view: RemoteView, base: SyncBase) {
        for id in view.unknown.sorted() {
            if let record = view.tree.unreadable[id] {
                let place = base.paths[id].map { "/" + $0 } ?? "item \(id)"
                report(SyncEvent(.unreadable, place, record.reason.description))
            } else if let place = base.paths[id] {
                report(SyncEvent(.unreadable, "/" + place, "it's in a folder that can't be read"))
            }
        }
    }

    /// Puts back anything left mid-move by a pass that was killed: at its old path if that's
    /// free, else at the top as `name (recovered)`.
    private func recoverStaging() {
        guard let tokens = try? FileManager.default.contentsOfDirectory(atPath: folder.staging) else { return }
        let journal =
            (FileManager.default.contents(atPath: folder.journal)).flatMap {
                try? JSONDecoder().decode([String: String].self, from: $0)
            } ?? [:]
        for token in tokens {
            let from = "\(folder.staging)/\(token)"
            if let original = journal[token], LocalFS.isFolder("\(root)/\(original)".parentPathAbsolute),
                LocalFS.move(from, to: "\(root)/\(original)")
            {
                continue
            }
            let name = journal[token].map { String($0.split(separator: "/").last ?? "item") } ?? token
            let recovered = ConflictName.make(for: name) { LocalFS.exists("\(root)/\($0)") }
            LocalFS.move(from, to: "\(root)/\(recovered)")
        }
        try? FileManager.default.removeItem(atPath: folder.journal)
    }
}

/// Applies one `SyncPlan`: first rearranges the folder (moves, deletes, new folders: no
/// network), then updates the drive, then downloads. Keeps track of where everything is as it
/// goes, and which merged items got all the way there (only those are saved as agreed).
final class SyncRun {
    enum Step { case local, remote, download }

    let plan: SyncPlan
    let base: SyncBase
    let local: LocalView
    let remote: RemoteView
    let root: String
    let folder: StateFolder
    let drive: Drive
    let log: (SyncEvent) -> Void

    /// Merged ID → local ID, growing as things are created here.
    private var localSource: [String: String]
    /// Local ID → merged ID, as planned.
    private let mergedOf: [String: String]
    /// The folder's layout by local ID, kept current as things move.
    private var localParent: [String: String?]
    private var localName: [String: String]
    private var stats: [String: FileStat]
    /// Local IDs whose stat was taken right after this pass wrote them.
    private var wroteHere: Set<String> = []
    private var staged: [String: String] = [:]
    /// Merged temporary ID → node ID, once created on the drive.
    private var created: [String: String] = [:]
    private var nodes: [String: Node]
    private var pending: [String: Set<Step>] = [:]
    private var blocked: Set<String> = []
    private var deletedHere: Set<String> = []
    private var deletedThere: Set<String> = []
    private var order: [String] = []
    private var mergedPaths: [String: String] = [:]
    private var counter = 0
    private(set) var wroteRemote = false
    private(set) var changes = 0

    init(
        plan: SyncPlan, base: SyncBase, local: LocalView, remote: RemoteView, root: String, folder: StateFolder,
        drive: Drive, log: @escaping (SyncEvent) -> Void
    ) {
        self.plan = plan
        self.base = base
        self.local = local
        self.remote = remote
        self.root = root
        self.folder = folder
        self.drive = drive
        self.log = log
        localSource = plan.localSource
        mergedOf = Dictionary(plan.localSource.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        localParent = local.entries.mapValues(\.parent)
        localName = local.entries.mapValues(\.name)
        stats = local.stats
        nodes = remote.tree.nodes

        // Parents before children.
        var children: [String?: [String]] = [:]
        for (id, entry) in plan.merged { children[entry.parent, default: []].append(id) }
        var queue: [(String?, String)] = [(nil, "")]
        while !queue.isEmpty {
            let (parent, path) = queue.removeFirst()
            for id in (children[parent] ?? []).sorted() {
                let childPath = path.isEmpty ? plan.merged[id]!.name : "\(path)/\(plan.merged[id]!.name)"
                mergedPaths[id] = childPath
                order.append(id)
                queue.append((id, childPath))
            }
        }
        for id in order { pending[id] = plan.held.contains(id) ? [] : steps(for: id) }
        for (copy, original) in plan.splitFrom {
            log(SyncEvent(.conflict, display(original), display(copy)))
            changes += 1
        }
        for (id, before) in plan.renamed where plan.splitFrom[id] == nil {
            let folder = mergedPaths[id]!.parentPath
            log(SyncEvent(.renamed, "/" + (folder.isEmpty ? before : "\(folder)/\(before)"), display(id)))
            changes += 1
        }
    }

    private func steps(for id: String) -> Set<Step> {
        let entry = plan.merged[id]!
        var steps: Set<Step> = []
        let here = localSource[id].flatMap { local.entries[$0] }
        if plan.splitFrom[id] != nil {
            steps.insert(.local)  // done along with the original's download
        } else if let here, let localID = localSource[id] {
            let parentNow = here.parent.map { mergedOf[$0] ?? "?" }
            if parentNow != entry.parent || here.name != entry.name { steps.insert(.local) }
            if !entry.isFolder, here.sha256 != entry.sha256 { steps.insert(.download) }
            if local.frozen.contains(localID), !steps.isEmpty { blocked.insert(id) }
        } else {
            steps.insert(entry.isFolder ? .local : .download)
        }
        if let there = remote.entries[id] {
            if there.location != entry.location || (!entry.isFolder && there.sha256 != entry.sha256) {
                steps.insert(.remote)
            }
        } else {
            steps.insert(.remote)
        }
        return steps
    }

    /// Local ID for something this pass creates here; distinct from the folder's own IDs (node
    /// IDs and `+<path>`), which matters when a conflicted copy keeps an item's old local ID.
    private static func createdHere(_ mergedID: String) -> String { "=" + mergedID }

    private func display(_ mergedID: String) -> String { "/" + (mergedPaths[mergedID] ?? "?") }
    private func absolute(_ relative: String) -> String { "\(root)/\(relative)" }

    /// Where a local item is right now.
    private func currentPath(_ localID: String) -> String {
        if let staged = staged[localID] { return staged }
        let name = localName[localID]!
        guard let parent = localParent[localID] ?? nil else { return absolute(name) }
        return "\(currentPath(parent))/\(name)"
    }

    private func noteWritten(_ localID: String, at path: String) {
        if let now = LocalFS.status(path) { stats[localID] = now.stat }
        wroteHere.insert(localID)
    }

    private func finish(_ id: String, _ step: Step) { pending[id]?.remove(step) }

    private func block(_ id: String, _ reason: String? = nil) {
        blocked.insert(id)
        if let reason { log(SyncEvent(.skipped, display(id), reason)) }
    }

    private func nextScratchName() -> String {
        counter += 1
        return String(counter)
    }

    // MARK: 1. The folder: moves, deletions, new folders

    func arrangeFolder() throws {
        // Move what moves out of the way first (deepest first, so nothing moves under it),
        // so swaps and moves into folders that are about to be created work.
        let moving = order.filter {
            pending[$0]!.contains(.local) && plan.splitFrom[$0] == nil && !blocked.contains($0)
                && localSource[$0] != nil
        }
        .map { localSource[$0]! }
        .sorted { local.paths[$0]!.depth > local.paths[$1]!.depth }
        if !moving.isEmpty {
            try FileManager.default.createDirectory(atPath: folder.staging, withIntermediateDirectories: true)
            var journal: [String: String] = [:]
            var tokens: [String: String] = [:]
            for localID in moving {
                let token = nextScratchName()
                tokens[localID] = token
                journal[token] = local.paths[localID]
            }
            try JSONEncoder().encode(journal).write(to: URL(fileURLWithPath: folder.journal))
            for localID in moving {
                let to = "\(folder.staging)/\(tokens[localID]!)"
                if LocalFS.move(currentPath(localID), to: to) {
                    staged[localID] = to
                } else {
                    block(mergedOf[localID]!, "couldn't move it (\(LocalFS.errorDescription()))")
                }
            }
        }
        defer {
            // Never leave anything in staging: it would look deleted.
            for (localID, path) in staged {
                let original = absolute(local.paths[localID]!)
                if LocalFS.isFolder(original.parentPathAbsolute), LocalFS.move(path, to: original) { continue }
                let name = localName[localID]!
                LocalFS.move(path, to: absolute(ConflictName.make(for: name) { LocalFS.exists(self.absolute($0)) }))
            }
            staged = [:]
            try? FileManager.default.removeItem(atPath: folder.staging)
            try? FileManager.default.removeItem(atPath: folder.journal)
        }

        // Delete what's gone: deepest first, and only if unchanged since the folder was listed.
        let doomed = local.entries.keys.filter { mergedOf[$0] == nil && !local.frozen.contains($0) }
            .sorted { local.paths[$0]!.depth > local.paths[$1]!.depth }
        let doomedSet = Set(doomed)
        for localID in doomed {
            let path = currentPath(localID)
            let removed =
                local.entries[localID]!.isFolder
                ? LocalFS.removeFolder(path)
                : LocalFS.status(path)?.stat == stats[localID] && LocalFS.removeFile(path)
            guard removed else { continue }
            deletedHere.insert(localID)
            if let parent = local.entries[localID]!.parent, doomedSet.contains(parent) { continue }
            log(SyncEvent(.deletedHere, "/" + local.paths[localID]!))
            changes += 1
        }

        // Put things where they go, and create new folders: parents first.
        for id in order where pending[id]!.contains(.local) && plan.splitFrom[id] == nil && !blocked.contains(id) {
            let entry = plan.merged[id]!
            let target = absolute(mergedPaths[id]!)
            let parentLocal: String?? = entry.parent.map { localSource[$0] }
            guard parentLocal != .some(nil) else {
                block(id)
                continue
            }
            if let localID = localSource[id] {
                guard let from = staged[localID] else { continue }
                guard LocalFS.move(from, to: target) else {
                    block(id, "couldn't move it into place (\(LocalFS.errorDescription()))")
                    continue
                }
                staged[localID] = nil
                localParent[localID] = parentLocal ?? nil
                localName[localID] = entry.name
                noteWritten(localID, at: target)
                log(SyncEvent(.movedHere, "/" + local.paths[localID]!, display(id)))
            } else {
                guard LocalFS.makeFolder(target) else {
                    block(id, "couldn't create it (\(LocalFS.errorDescription()))")
                    continue
                }
                let localID = Self.createdHere(id)
                localSource[id] = localID
                localParent[localID] = parentLocal ?? nil
                localName[localID] = entry.name
                noteWritten(localID, at: target)
                log(SyncEvent(.createdFolderHere, display(id)))
            }
            changes += 1
            finish(id, .local)
        }
    }

    // MARK: 2. The drive: new things, edits, moves, then deletions

    func updateDrive() async throws {
        for id in order where pending[id]!.contains(.remote) && !blocked.contains(id) {
            let entry = plan.merged[id]!
            var parent: String? = nil
            if let parentID = entry.parent {
                let onDrive = remote.entries[parentID] != nil || plan.held.contains(parentID)
                guard onDrive || created[parentID] != nil else {
                    blocked.insert(id)
                    continue
                }
                parent = created[parentID] ?? parentID
            }
            let node: Node
            if let existing = nodes[id], remote.entries[id] != nil {
                if !entry.isFolder, entry.sha256 != existing.record.sha256 {
                    guard let uploaded = try await upload(id, as: entry.name, in: parent, replacing: existing) else {
                        continue
                    }
                    node = uploaded
                    if remote.entries[id]!.location != entry.location {
                        log(SyncEvent(.movedOnDrive, remote.tree.path(of: existing).description, display(id)))
                        changes += 1
                    }
                    log(SyncEvent(.uploaded, display(id)))
                } else {
                    node = try await drive.move(existing, to: parent, as: entry.name)
                    log(SyncEvent(.movedOnDrive, remote.tree.path(of: existing).description, display(id)))
                }
            } else if entry.isFolder {
                node = try await drive.createFolder(named: entry.name, in: parent)
                created[id] = node.id
                log(SyncEvent(.createdFolderOnDrive, display(id)))
            } else {
                guard let uploaded = try await upload(id, as: entry.name, in: parent) else { continue }
                node = uploaded
                created[id] = node.id
                log(SyncEvent(.uploaded, display(id)))
            }
            nodes[node.id] = node
            wroteRemote = true
            changes += 1
            finish(id, .remote)
        }

        // Deleted here: delete on the drive, along with anything ignored inside deleted folders.
        // A folder that still holds something kept (whose move was skipped) waits for next time.
        var doomed = Set(remote.entries.keys.filter { plan.merged[$0] == nil })
        var holding = Set(plan.merged.keys.compactMap { nodes[created[$0] ?? $0]?.record.parent })
        while let folder = holding.first(where: doomed.contains) {
            doomed.remove(folder)
            holding.remove(folder)
            if let parent = nodes[folder]?.record.parent { holding.insert(parent) }
        }
        guard !doomed.isEmpty else { return }
        var all = doomed
        for id in doomed where remote.entries[id]!.isFolder {
            for inside in remote.tree.descendants(of: id)
            where remote.entries[inside.id] == nil && !remote.unknown.contains(inside.id) {
                all.insert(inside.id)
            }
        }
        let ordered = all.compactMap { nodes[$0] }.sorted {
            remote.tree.path(of: $0).components.count > remote.tree.path(of: $1).components.count
        }
        try await drive.delete(ordered)
        wroteRemote = true
        deletedThere = all
        let paths = Dictionary(uniqueKeysWithValues: doomed.map { ($0, remote.tree.path(of: nodes[$0]!).description) })
        for id in doomed.sorted(by: { paths[$0]! < paths[$1]! }) {
            if let parent = remote.entries[id]!.parent, paths[parent] != nil { continue }  // reported with its folder
            log(SyncEvent(.deletedFromDrive, paths[id]!))
            changes += 1
        }
    }

    /// Uploads a merged item's local file. `nil` (and the item is left for next time) if the
    /// file can't be read, e.g. because it was deleted since the folder was listed.
    private func upload(_ id: String, as name: String, in parent: String?, replacing existing: Node? = nil)
        async throws -> Node?
    {
        guard let localID = localSource[id] else {
            blocked.insert(id)
            return nil
        }
        let path = currentPath(localID)
        do {
            return try await drive.upload(URL(fileURLWithPath: path), as: name, in: parent, replacing: existing)
        } catch  where Self.isLocal(error) {
            block(id, "couldn't read it (\(error.localizedDescription))")
            return nil
        }
    }

    /// A problem with a file on this computer (gone, unreadable, disk full), not the network.
    private static func isLocal(_ error: Error) -> Bool {
        error is CocoaError || (error as NSError).domain == NSPOSIXErrorDomain
    }

    // MARK: 3. Downloads

    func download() async throws {
        let copies = Dictionary(plan.splitFrom.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for id in order where pending[id]!.contains(.download) && !blocked.contains(id) {
            let entry = plan.merged[id]!
            guard let node = nodes[created[id] ?? id] else { continue }
            let parentLocal: String?? = entry.parent.map { localSource[$0] }
            guard parentLocal != .some(nil) else {
                blocked.insert(id)
                continue
            }
            try FileManager.default.createDirectory(atPath: folder.downloads, withIntermediateDirectories: true)
            let scratch = "\(folder.downloads)/\(nextScratchName())"
            do {
                try await drive.download(node, to: URL(fileURLWithPath: scratch))
            } catch let error as ATDriveError {
                block(id, error.description)
                continue
            } catch  where Self.isLocal(error) {
                block(id, "couldn't save it (\(error.localizedDescription))")
                continue
            }
            defer { LocalFS.removeFile(scratch) }
            let target = absolute(mergedPaths[id]!)

            // Edited in both places: the local file becomes the conflicted copy.
            if let copy = copies[id] {
                guard !blocked.contains(copy), let localID = localSource[copy] else {
                    blocked.insert(id)
                    continue
                }
                let from = currentPath(localID)
                let copyTarget = absolute(mergedPaths[copy]!)
                guard LocalFS.status(from)?.stat == stats[localID], LocalFS.move(from, to: copyTarget) else {
                    block(id, "it changed again here; trying again")
                    blocked.insert(copy)
                    continue
                }
                localParent[localID] = plan.merged[copy]!.parent.flatMap { localSource[$0] }
                localName[localID] = plan.merged[copy]!.name
                noteWritten(localID, at: copyTarget)
                finish(copy, .local)
            }

            if let localID = localSource[id] {
                // An edit from the drive: replace the file, unless it changed here since.
                guard LocalFS.status(target)?.stat == stats[localID] else {
                    block(id, "it changed here since; trying again")
                    continue
                }
                LocalFS.copyPermissions(from: target, to: scratch)
                guard rename(scratch, target) == 0 else {
                    block(id, "couldn't replace it (\(LocalFS.errorDescription()))")
                    continue
                }
                noteWritten(localID, at: target)
            } else {
                guard LocalFS.move(scratch, to: target) else {
                    block(id, LocalFS.exists(target) ? "something else is there now" : LocalFS.errorDescription())
                    continue
                }
                let localID = Self.createdHere(id)
                localSource[id] = localID
                localParent[localID] = parentLocal ?? nil
                localName[localID] = entry.name
                noteWritten(localID, at: target)
            }
            log(SyncEvent(.downloaded, display(id)))
            changes += 1
            finish(id, .download)
        }
    }

    // MARK: Result

    /// What both sides now agree on: everything that got all the way there, plus the last
    /// sync's view of anything that didn't (so the next pass picks it up where this one left).
    func agreedItems() -> [String: SyncState.Item] {
        var items = base.items
        for id in base.items.keys where plan.merged[id] == nil {
            let goneHere = local.entries[id] == nil || deletedHere.contains(id) || mergedOf[id] != nil
            let goneThere = remote.entries[id] == nil || deletedThere.contains(id)
            if goneHere && goneThere { items[id] = nil }
        }
        let recently = Int64((Date().timeIntervalSince1970 - 2) * 1_000_000_000)
        for id in order where pending[id]!.isEmpty && !blocked.contains(id) && !plan.held.contains(id) {
            let entry = plan.merged[id]!
            guard let localID = localSource[id], !local.frozen.contains(localID), var stat = stats[localID]
            else { continue }
            // Timestamps are coarse (a few ms, or worse), so a file changed just before it was
            // listed could change again without its stat changing. Make sure it's read again.
            if !entry.isFolder, !wroteHere.contains(localID), stat.changed > recently { stat.changed = 0 }
            let nodeID = created[id] ?? id
            let parent = entry.parent.map { created[$0] ?? $0 }
            if let parent, parent.hasPrefix("+") { continue }
            items[nodeID] = SyncState.Item(
                parent: parent, name: entry.name, folder: entry.isFolder,
                sha256: entry.isFolder ? nil : nodes[nodeID]?.record.sha256 ?? entry.sha256, stat: stat)
        }
        return items
    }
}

extension String {
    /// The folder an absolute path is in.
    var parentPathAbsolute: String {
        let parent = parentPath
        return parent.isEmpty ? "/" : parent
    }
}

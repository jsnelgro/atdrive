import ATDriveCore
import ArgumentParser
import Foundation

struct ShowHistory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Show what changed: when, how, on which device, and where.",
        discussion: """
            With a file: its changes. With a folder: changes to it and to everything that was in it at the time. With no path: the whole drive. Newest first. Something deleted is found in the trash, under the path it had.

            Each line starts with the change's version ID. Give it to --at (ls, tree, get, cat and restore take it) to see or restore the drive as it was just after that change.

            "lost a race" marks a change made at the same moment as another device's change to the same thing, which won. It stays in history, and syncing brings a lost edit back as a conflicted copy.
            """
    )

    @Argument(help: "File or folder in the drive (default: the whole drive).")
    var path: String?

    @Option(name: [.customShort("n"), .long], help: "Show at most this many changes (0 for all).")
    var limit = 50

    func validate() throws {
        if limit < 0 { throw ValidationError("--limit can't be negative") }
    }

    func run() async throws {
        let context = try await Context.load()
        var snapshot = try await context.snapshot()
        var scope = DriveHistory.Scope.drive
        if let path {
            let (_, space, local) = try await context.space(of: DrivePath(path), writing: false)
            snapshot = space
            let found = try snapshot.find(local)
            if let id = found.id { scope = found.isFolder ? .folder(id) : .node(id) }
        }
        let entries = snapshot.entries(scope)
        guard !entries.isEmpty else {
            print(path.map { "No changes recorded for \(DrivePath($0))." } ?? "No changes recorded.")
            return
        }
        let shown = limit > 0 ? Array(entries.prefix(limit)) : entries
        // To show where a moved thing came from.
        var known = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func entry(_ id: String, of node: String) -> DriveHistory.Entry? {
            if let entry = known[id] { return entry }
            for entry in snapshot.entries(.node(node)) { known[entry.id] = entry }
            return known[id]
        }

        let deviceWidth = min(shown.map { Self.device($0).count }.max() ?? 0, 24)
        for change in shown {
            var what = change.path.map { Self.describe($0, change.record) } ?? "(no longer in history)"
            var label = change.change.rawValue
            var notes: [String] = []
            switch change.change {
            case .moved:
                if let prev = change.version.record.prev, let from = entry(prev, of: change.node)?.path,
                    let to = change.path, from != to
                {
                    if from.parent == to.parent { label = "renamed" }
                    what = "\(Self.describe(from, change.record)) → \(what)"
                }
            case .created, .edited, .restored:
                if let record = change.record, record.kind == .file { notes.append(Output.size(record.size ?? 0)) }
            case .deleted:
                break
            case .shared:
                notes.append("moved into its own space, to share")
            }
            if change.lost { notes.append("lost a race") }
            let note = notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"
            print(
                "\(change.id)  \(Output.date(change.date))  \(label.rightPadded(8))  "
                    + "\(Self.device(change).rightPadded(deviceWidth))  \(what)\(note)")
        }
        if shown.count < entries.count {
            print("(\(shown.count) of \(entries.count) changes; --limit 0 shows them all)")
        }
    }

    private static func device(_ entry: DriveHistory.Entry) -> String { entry.device.isEmpty ? "-" : entry.device }

    private static func describe(_ path: DrivePath, _ record: NodeRecord?) -> String {
        record.map { $0.kind != .file } == true && !path.isRoot ? "\(path)/" : path.description
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bring something back: from the trash, or as it was before its last change.",
        discussion: """
              atdrive restore /notes.txt              deleted: back from the trash; otherwise its last change undone
              atdrive restore /notes.txt --at 2h      as it was 2 hours ago
              atdrive restore /docs --at 2026-11-08   a folder, with what was in it

            Without --at, something deleted comes back from the trash where it was (a folder with what was deleted with it; as "name (conflicted copy <date>)" if the name is taken by now), and anything else has its latest change undone. It says which it did.

            Contents, name and place all go back. With --at, the path is looked up as of then, so something renamed, moved or deleted since is found under the path it had. A folder gets back what was in it then, and keeps what was added since.

            A restore is a change like any other, so it can be undone too.
            """
    )

    @Argument(help: "File or folder in the drive.")
    var path: String

    @Option(help: When.help("Put it back"), transform: When.parse)
    var at: Date?

    func run() async throws {
        let (drive, snapshot, path) = try await Context.load().space(of: DrivePath(path), writing: true)
        var past: DriveTree?
        let result: Drive.RestoreResult
        var undoingDelete = false
        if let when = at {
            Output.warnIfBeforeHistory(when, snapshot)
            let then = snapshot.tree(at: when)
            past = then
            guard let node = try then.locate(path) else {
                throw CommandError("pick a file or folder to restore, not the whole drive")
            }
            result = try await drive.restore(node.id, asOf: when, in: snapshot)
        } else {
            let found = try snapshot.find(path)
            guard let id = found.id else {
                throw CommandError("pick a file or folder to restore, not the whole drive")
            }
            if case .trashed = found {
                print("Bringing \(path) back from the trash.")
                let restored = try await drive.restoreFromTrash([id], in: snapshot)
                let after = try await drive.update(snapshot)
                for node in restored.restored { print("↺ \(Output.path(of: node.id, in: after))") }
                Output.reportSkipped(restored, before: snapshot)
                return
            }
            let history = snapshot.history
            guard let before = history.previousVersion(of: id, current: snapshot.tree) else {
                throw CommandError("\(path): nothing to undo (no earlier version in history)")
            }
            if let latest = Self.latestChange(of: id, in: snapshot) {
                let nouns: [VersionRecord.Change: String] = [
                    .edited: "edit", .moved: "move", .deleted: "delete", .restored: "restore",
                ]
                let device = latest.record.device.isEmpty ? "" : " on \(latest.record.device)"
                print(
                    "Undoing the \(nouns[latest.record.change] ?? "change") from \(Output.date(latest.date))\(device).")
            }
            undoingDelete = history.record(at: before) == nil
            result = try await drive.restorePrevious(id, in: snapshot)
        }

        let after = try await drive.update(snapshot)
        for node in result.restored {
            print("↺ \(Output.path(of: node.id, in: after, past: past))")
        }
        Output.reportSkipped(result, before: snapshot, past: past)
        if undoingDelete {
            print("✗ \(path)  (back in the trash)")
        } else if result.restored.isEmpty, result.skipped.isEmpty {
            print("\(path) is already as it was\(at == nil ? "" : " then").")
        }
    }

    /// The change a restore without `--at` undoes: the node's current version.
    private static func latestChange(of id: String, in snapshot: DriveSnapshot) -> Version? {
        if let version = snapshot.tree.nodes[id]?.record.version { return snapshot.history.version(version) }
        return snapshot.trash().first { $0.id == id }?.deletion
    }
}

struct Trash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What's in the trash (`--all`: with what was deleted along with its folder).",
        discussion: """
              atdrive trash                       what's in it
              atdrive restore /notes.txt          bring something back where it was
              atdrive trash empty                 delete everything in it for good
              atdrive trash empty /notes.txt      just that, for good

            Deleted files and folders stay in the trash for \(DriveSettings.defaultRetentionDays) days (as long as the drive keeps history), then they're gone for good. To get rid of something for good now, `atdrive rm` it, then `atdrive trash empty` it.
            """,
        subcommands: [TrashList.self, TrashEmpty.self],
        defaultSubcommand: TrashList.self
    )
}

struct TrashList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List what's in the trash, latest first.", shouldDisplay: false)

    @Flag(name: .shortAndLong, help: "Also list what was deleted along with its folder.")
    var all = false

    func run() async throws {
        let snapshot = try await Context.load().snapshot()
        let now = Date()
        let items = snapshot.trash(now: now).filter { all || !$0.deletedWithFolder }
        guard !items.isEmpty else {
            print("The trash is empty.")
            return
        }
        for item in items {
            let size = item.isFolder ? "-" : Output.size(item.record.size ?? 0)
            var line = "\(size.leftPadded(9))  \(Output.date(item.deletedAt).leftPadded(16))  \(Output.path(item))"
            if item.isFolder, !all {
                let inside = snapshot.deletedTogether(item, now: now).count - 1
                if inside > 0 { line += "  (and \(Output.count(inside, "item")) in it)" }
            }
            print(line)
        }
        print(
            "\nDeleted things stay here for \(Output.days(snapshot.retention)). "
                + "`atdrive restore <path>` brings one back.")
    }
}

struct TrashEmpty: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "empty",
        abstract: "Delete what's in the trash for good, with its history: all of it, or just these.",
        discussion: """
            Nothing of it can be restored afterwards: every version goes too. Give the paths things had when they were deleted to empty just those (a folder goes with what was deleted with it).
            """)

    @Argument(help: "Where things in the trash were (default: everything in it).")
    var paths: [String] = []

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() async throws {
        let context = try await Context.load()
        guard !paths.isEmpty else { return try await emptyAll(context.drive) }
        let (drive, snapshot, _) = try await context.space(of: DrivePath(paths[0]), writing: true)
        // Check every path before deleting anything.
        var targets: [(id: String, line: String)] = []
        for raw in paths {
            let (other, _, path) = try await context.space(of: DrivePath(raw), writing: true)
            guard other === drive else { throw CommandError("empty things from one shared folder at a time") }
            guard let item = snapshot.trashed(at: path) else {
                let isThere = (try? snapshot.tree.find(path)).map { $0 != .missing } ?? false
                throw CommandError(
                    "\(path): not in the trash\(isThere ? " (it's in the drive: `atdrive rm` it first)" : "")")
            }
            var line = item.isFolder ? "\(path)/" : path.description
            let inside = snapshot.deletedTogether(item).count - 1
            if inside > 0 { line += "  (with \(Output.count(inside, "item")) in it)" }
            if !targets.contains(where: { $0.id == item.id }) { targets.append((item.id, line)) }
        }
        if !yes {
            let question = "Delete \(targets.count == 1 ? "this" : "these") for good, with all history?"
            guard try Output.confirm(question, about: targets.map(\.line)) else {
                print("Nothing was deleted.")
                return
            }
        }
        for target in targets {
            try await drive.purge([target.id], in: snapshot)
            print("✗ \(target.line)")
        }
    }

    private func emptyAll(_ drive: Drive) async throws {
        let snapshot = try await drive.update(nil)
        // Everything `emptyTrash` deletes, including what's past the retention period.
        let count = snapshot.history.trash(current: snapshot.tree).count
        guard count > 0 else {
            print("The trash is already empty.")
            return
        }
        guard try yes || Output.confirm("Delete the \(Output.count(count, "item")) in the trash for good?") else {
            print("Nothing was deleted.")
            return
        }
        try await drive.emptyTrash(in: snapshot)
        print("✗ Emptied the trash (\(Output.count(count, "item")))")
    }
}

struct DiskUsage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "du", abstract: "Show the space the drive uses, now and for its history.",
        discussion: """
            A chunk of a file is stored once, however many files and versions use it. So history costs only what changed: older versions, and what's in the trash.
            """
    )

    func run() async throws {
        let snapshot = try await Context.load().snapshot()
        let usage = snapshot.usage()
        let files = snapshot.tree.nodes.values.filter { !$0.isFolder }
        let fileBytes = files.reduce(0) { $0 + ($1.record.size ?? 0) }
        var current = Output.count(files.count, "file")
        if fileBytes != usage.current { current += " adding up to \(Output.size(fileBytes))" }
        let rows = [
            ("current files:", usage.current, "(\(current))"),
            ("history only:", usage.historyOnly, "(older versions and the trash)"),
            ("total:", usage.total, ""),
        ]
        for (label, bytes, note) in rows {
            print("\(label.rightPadded(14))  \(Output.size(bytes).leftPadded(9))\(note.isEmpty ? "" : "  \(note)")")
        }
        print(
            "\nHistory shares \(Output.size(usage.shared)) with current files: a chunk is stored once, "
                + "however many files and versions use it.")
    }
}

// MARK: Shared

/// `--at <when>`: the drive as it was at a time (`PointInTime`).
enum When {
    static func help(_ action: String) -> ArgumentHelp {
        ArgumentHelp(
            "\(action) as it was then: 2h, 30m or 3d ago; 2026-11-08 (the start of that day, local time); "
                + "2026-11-08T14:00 (local time); or a version ID from `atdrive history`.",
            valueName: "when")
    }

    /// For `transform:`, so a mistake is reported with the command's usage.
    @Sendable static func parse(_ text: String) throws -> Date {
        do {
            return try PointInTime.parse(text)
        } catch let error as PointInTime.ParseError {
            throw CommandError(error.reason)  // ArgumentParser quotes the text already
        }
    }
}

extension Context {
    /// The drive with its history and settings.
    func snapshot() async throws -> DriveSnapshot { try await drive.update(nil) }

    /// The drive as it is now, or as it was at `date`: every space in it.
    func tree(at date: Date?) async throws -> DriveTree {
        let joined = try await self.joined.update(nil)
        guard let date else { return joined.tree }
        Output.warnIfBeforeHistory(date, joined.home)
        return joined.tree(at: date)
    }

    /// History is per space: the space a path is in (the home drive, or a shared folder mounted
    /// in it), its snapshot, and the path within it. `writing`: for a change, which a folder
    /// shared with you can't take.
    func space(of path: DrivePath, writing: Bool) async throws -> (
        drive: Drive, snapshot: DriveSnapshot, path: DrivePath
    ) {
        let joined = try await self.joined.update(nil)
        for length in stride(from: path.components.count, through: 1, by: -1) {
            let prefix = DrivePath(components: Array(path.components.prefix(length)))
            guard case .node(let node)? = try? joined.tree.find(prefix), node.isMount,
                let state = joined.mounts[node.id]
            else { continue }
            if writing, state.readOnly { throw ATDriveError.readOnly(path: path.description, owner: state.owner) }
            guard let drive = self.joined.drive(ofMount: node.id), let snapshot = state.snapshot else {
                throw ATDriveError.mountUnavailable(
                    path: prefix.description, why: state.problem?.description ?? "it can't be read")
            }
            if length == path.components.count, writing {
                throw CommandError("\(path) is a shared folder: its history is inside it (try \(path)/<name>)")
            }
            return (drive, snapshot, DrivePath(components: Array(path.components.dropFirst(length))))
        }
        return (self.drive, joined.home, path)
    }
}

/// A command that can't do what it was asked, and why.
struct CommandError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

extension Output {
    /// "1 item", "3 items".
    static func count(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    static func days(_ interval: TimeInterval) -> String { count(Int((interval / 86400).rounded()), "day") }

    /// Where a node is in `snapshot`, or else where it was then (`past`), or in the trash.
    static func path(of id: String, in snapshot: DriveSnapshot, past: DriveTree? = nil) -> String {
        if let node = snapshot.tree.nodes[id] { return folderSlash(snapshot.tree.path(of: node), node.isFolder) }
        if let past, let node = past.nodes[id] { return folderSlash(past.path(of: node), node.isFolder) }
        if let item = snapshot.trash().first(where: { $0.id == id }) { return path(item) }
        return "item \(id)"
    }

    static func path(_ item: DriveHistory.TrashItem) -> String { folderSlash(item.path, item.isFolder) }

    private static func folderSlash(_ path: DrivePath, _ isFolder: Bool) -> String {
        isFolder && !path.isRoot ? "\(path)/" : path.description
    }

    /// Says what a restore couldn't put back, and why.
    static func reportSkipped(_ result: Drive.RestoreResult, before snapshot: DriveSnapshot, past: DriveTree? = nil) {
        for id in result.skipped {
            let why =
                switch result.reasons[id] {
                case .contentsGone?: "its contents are no longer in history"
                case .unreadable?: "it can't be read here"
                case .changedElsewhere?, nil: "it changed on another device at the same moment; try again"
                }
            warn("skipped \(path(of: id, in: snapshot, past: past)): \(why)")
        }
    }

    /// The drive as of before its history period may be incomplete: pruning keeps only what's
    /// needed from the start of the period on.
    static func warnIfBeforeHistory(_ date: Date, _ snapshot: DriveSnapshot, now: Date = Date()) {
        guard date < now - snapshot.retention else { return }
        warn(
            "the drive keeps \(days(snapshot.retention)) of history, so it may not be complete as of \(Output.date(date))"
        )
    }

    /// Asks a yes-or-no question on the terminal, after listing what it's about. Without a
    /// terminal, there's no one to ask.
    static func confirm(_ question: String, about lines: [String] = []) throws -> Bool {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CommandError("can't ask for confirmation without a terminal; add --yes")
        }
        let text = lines.map { "  \($0)\n" }.joined() + "\(question) [y/N] "
        FileHandle.standardError.write(Data(text.utf8))
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

extension String {
    func rightPadded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

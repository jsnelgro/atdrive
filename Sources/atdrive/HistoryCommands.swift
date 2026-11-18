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
        let snapshot = try await Context.load().snapshot()
        var scope = DriveHistory.Scope.drive
        if let path {
            let found = try snapshot.find(DrivePath(path))
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
        record?.kind == .folder && !path.isRoot ? "\(path)/" : path.description
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put a file or folder back as it was.",
        discussion: """
              atdrive restore /notes.txt --previous   undo its latest change
              atdrive restore /notes.txt --at 2h      as it was 2 hours ago
              atdrive restore /docs --at 2026-11-08   a folder, with what was in it

            Contents, name and place all go back. With --at, the path is looked up as of then, so something renamed, moved or deleted since is found under the path it had. A folder gets back what was in it then, and keeps what was added since.

            A restore is a change like any other, so it can be undone too.
            """
    )

    @Argument(help: "File or folder in the drive.")
    var path: String

    @Option(help: When.help("Put it back"), transform: When.parse)
    var at: Date?

    @Flag(help: "Undo its latest change.")
    var previous = false

    func validate() throws {
        if at == nil, !previous { throw ValidationError("say when: --at <when>, or --previous") }
        if at != nil, previous { throw ValidationError("choose --at or --previous") }
    }

    func run() async throws {
        let drive = try await Context.load().drive
        let snapshot = try await drive.update(nil)
        let path = DrivePath(path)
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
            guard let id = try snapshot.find(path).id else {
                throw CommandError("pick a file or folder to restore, not the whole drive")
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

    /// The change `--previous` undoes: the node's current version, or its delete.
    private static func latestChange(of id: String, in snapshot: DriveSnapshot) -> Version? {
        if let version = snapshot.tree.nodes[id]?.record.version { return snapshot.history.version(version) }
        return snapshot.trash().first { $0.id == id }?.deletion
    }
}

struct Trash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "See what was deleted, and bring it back.",
        discussion: """
              atdrive trash                       what's in it
              atdrive trash restore /notes.txt    bring something back where it was
              atdrive trash empty                 delete everything in it for good

            Deleted files and folders stay in the trash for \(DriveSettings.defaultRetentionDays) days (as long as the drive keeps history), then they're gone for good.
            """,
        subcommands: [TrashList.self, TrashRestore.self, TrashEmpty.self],
        defaultSubcommand: TrashList.self
    )
}

struct TrashList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List what's in the trash, latest first.")

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
                + "`atdrive trash restore <path>` brings one back.")
    }
}

struct TrashRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Bring things back from the trash, where they were.",
        discussion: """
            Give the paths things had when they were deleted. A folder comes back with what was deleted with it, and deleted folders it was in come back too. If the name is taken by now, it comes back as "name (conflicted copy <date>)". If several things were deleted from the same path, the latest one comes back.
            """
    )

    @Argument(help: "Where they were in the drive.")
    var paths: [String]

    func validate() throws {
        if paths.isEmpty { throw ValidationError("nothing to restore") }
    }

    func run() async throws {
        let drive = try await Context.load().drive
        let snapshot = try await drive.update(nil)
        var ids: [String] = []
        for raw in paths {
            let path = DrivePath(raw)
            guard let item = snapshot.trashed(at: path) else {
                let isThere = (try? snapshot.tree.find(path)).map { $0 != .missing } ?? false
                throw CommandError("\(path): not in the trash\(isThere ? " (it's in the drive)" : "")")
            }
            if !ids.contains(item.id) { ids.append(item.id) }
        }
        let result = try await drive.restoreFromTrash(ids, in: snapshot)
        let after = try await drive.update(snapshot)
        for node in result.restored { print("↺ \(Output.path(of: node.id, in: after))") }
        Output.reportSkipped(result, before: snapshot)
    }
}

struct TrashEmpty: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "empty", abstract: "Delete everything in the trash for good, with its history.")

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() async throws {
        let drive = try await Context.load().drive
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

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete files or folders now, with all their history.",
        discussion: """
            Unlike rm, nothing goes to the trash: every version is deleted too, so nothing of it can be restored. For things that mustn't stay around. A path that's not in the drive is looked up in the trash.
            """
    )

    @Argument(help: "Paths in the drive, or where things in the trash were.")
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Purge folders and everything in them.")
    var recursive = false

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func validate() throws {
        if paths.isEmpty { throw ValidationError("nothing to purge") }
    }

    func run() async throws {
        let drive = try await Context.load().drive
        let snapshot = try await drive.update(nil)
        // Check every path before deleting anything.
        var targets: [(id: String, line: String)] = []
        for raw in paths {
            let path = DrivePath(raw)
            let found = try snapshot.find(path)
            guard let id = found.id else { throw CommandError("refusing to purge the whole drive") }
            if found.isFolder, !recursive { throw ATDriveError.needsRecursive(path.description) }
            var line = found.isFolder ? "\(path)/" : path.description
            switch found {
            case .node(let node) where node.isFolder:
                let inside = snapshot.tree.descendants(of: id).count
                if inside > 0 { line += "  (and \(Output.count(inside, "item")) in it)" }
            case .trashed(let item):
                let inside = snapshot.deletedTogether(item).count - 1
                line += inside > 0 ? "  (in the trash, with \(Output.count(inside, "item")))" : "  (in the trash)"
            default:
                break
            }
            if !targets.contains(where: { $0.id == id }) { targets.append((id, line)) }
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

struct Prune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply the history period now: delete older versions.",
        discussion: """
            The drive keeps \(DriveSettings.defaultRetentionDays) days of history. What's needed to show the drive as it was at the start of that period stays. `atdrive sync` prunes once a day by itself.
            """
    )

    func run() async throws {
        let drive = try await Context.load().drive
        let snapshot = try await drive.update(nil)
        let removed = try await drive.prune(snapshot)
        let days = Output.days(snapshot.retention)
        if removed == 0 {
            print("Nothing to remove. History is kept for \(days).")
        } else {
            print("Removed \(Output.count(removed, "version")) from more than \(days) ago.")
        }
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

    /// The drive as it is now, or as it was at `date`.
    func tree(at date: Date?) async throws -> DriveTree {
        guard let date else { return try await drive.tree() }
        let snapshot = try await snapshot()
        Output.warnIfBeforeHistory(date, snapshot)
        return snapshot.tree(at: date)
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

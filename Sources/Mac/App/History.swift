import ATDriveCore
import AppKit
import Observation
import SwiftUI

/// History and the trash in the menu-bar app (#11): the Trash window (from the menu), and
/// Restore Previous Version… (from Finder, handed over as a `FinderRequest`): a file's versions,
/// or a folder's history and a time to put it back to. What they do is in the core
/// (`JoinedHistory.swift`), as `atdrive trash` and `atdrive restore` are.
@MainActor
enum HistoryWindows {
    private static weak var trash: NSWindow?

    /// Opens the Trash window, or brings it to the front.
    static func showTrash() {
        if let trash, trash.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            trash.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            guard let drive = await SharingCoordinator.shared.makeDrive?() else {
                return SharingCoordinator.shared.alert("Sign in to ATDrive first.")
            }
            trash = SharingCoordinator.shared.show(TrashView(model: TrashModel(drive: drive)), title: "Trash")
        }
    }
}

/// What a restore couldn't put back, and why, in a sentence: `nil` if it put back everything.
enum RestoreReport {
    static func problem(_ result: Drive.RestoreResult) -> String? {
        guard !result.skipped.isEmpty else { return nil }
        let reasons = Set(result.skipped.map { why(result.reasons[$0]) }).sorted()
        let count = result.skipped.count
        let what = count == 1 ? "One item" : "\(count) items"
        return "\(what) couldn't be put back: \(reasons.joined(separator: "; "))."
    }

    private static func why(_ skip: Drive.RestoreResult.Skip?) -> String {
        switch skip {
        case .contentsGone?: return "its contents are no longer in history"
        case .unreadable?: return "it can't be read on this Mac"
        case .changedElsewhere?, nil: return "it changed on another device at the same moment, so try again"
        }
    }

    /// "Nov 8, 2026 at 2:05:31 PM".
    static func when(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .standard) }

    /// "30 days".
    static func days(_ interval: TimeInterval) -> String {
        let days = Int((interval / 86400).rounded())
        return days == 1 ? "1 day" : "\(days) days"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: Trash

@MainActor @Observable
final class TrashModel {
    let drive: JoinedDrive
    private(set) var items: [JoinedSnapshot.TrashItem] = []
    /// Read at least once.
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var done: String?
    /// How long deleted things stay (the drive's settings).
    private(set) var retention = TimeInterval(DriveSettings.defaultRetentionDays) * 86400
    var selection: Set<String> = []
    @ObservationIgnored private var snapshot: JoinedSnapshot?

    init(drive: JoinedDrive) {
        self.drive = drive
    }

    func load() async {
        busy = true
        defer {
            busy = false
            loaded = true
        }
        do {
            show(try await drive.update(snapshot))
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    private func show(_ snapshot: JoinedSnapshot) {
        self.snapshot = snapshot
        items = snapshot.trash()
        retention = snapshot.home.retention
        let ids = Set(items.map(\.id))
        selection = selection.filter { ids.contains($0) }
    }

    /// Puts things back where they were, with the folders they were in (see
    /// `JoinedDrive.restoreFromTrash`).
    func restore(_ ids: Set<String>) async {
        guard !ids.isEmpty, !busy else { return }
        busy = true
        message = nil
        done = nil
        defer { busy = false }
        do {
            // Up to date: something may have been put back elsewhere since the list was read.
            let snapshot = try await drive.update(self.snapshot)
            let restoring = snapshot.trash().filter { ids.contains($0.id) }
            guard !restoring.isEmpty else {
                show(snapshot)
                message = "That's not in the trash any more."
                return
            }
            let result = try await drive.restoreFromTrash(restoring.map(\.id), in: snapshot)
            let put = restoring.count - Set(result.skipped).intersection(restoring.map(\.id)).count
            if put > 0 {
                let what = restoring.count == 1 ? "“\(restoring[0].name)”" : "\(put) items"
                done = "Put back \(what) where \(put == 1 ? "it was" : "they were")."
            }
            message = RestoreReport.problem(result)
            await SharingCoordinator.refreshFinder()
            show(try await drive.update(snapshot))
        } catch {
            message = String(describing: error)
        }
    }
}

struct TrashView: View {
    @State var model: TrashModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Table(model.items, selection: $model.selection) {
                TableColumn("Name") { item in
                    Label {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: item.isFolder ? "folder" : "doc")
                    }
                }
                .width(min: 140, ideal: 220)
                TableColumn("Where It Was") { item in
                    Text(item.folder.description)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 180)
                TableColumn("Deleted") { item in
                    Text(item.deletedAt.formatted(date: .abbreviated, time: .shortened))
                        .help(item.device.isEmpty ? "" : "On \(item.device)")
                }
                .width(min: 120, ideal: 150)
                TableColumn("Size") { item in
                    Text(Self.size(item)).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Restore") { Task { await model.restore(ids) } }
                    .disabled(ids.isEmpty || model.busy)
            } primaryAction: { ids in
                Task { await model.restore(ids) }
            }
            .overlay {
                if model.loaded, model.items.isEmpty, model.message == nil {
                    ContentUnavailableView(
                        "The Trash Is Empty", systemImage: "trash",
                        description: Text("What's deleted from your drive, anywhere, stays here for a while."))
                }
            }
            if let done = model.done {
                Label(done, systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Callout(text: message)
            }
            HStack {
                Text(
                    "Deleted things stay here for \(RestoreReport.days(model.retention)), then they're gone for good. Restoring one puts it back where it was."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Check again")
                .disabled(model.busy)
                Button("Restore") { Task { await model.restore(model.selection) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection.isEmpty || model.busy)
            }
        }
        .padding(16)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 340, idealHeight: 420)
        .task { await model.load() }
    }

    /// A file's size; for a folder, what was deleted with it.
    private static func size(_ item: JoinedSnapshot.TrashItem) -> String {
        if let size = item.size { return RestoreReport.size(size) }
        switch item.inside {
        case 0: return "Empty"
        case 1: return "1 item"
        default: return "\(item.inside) items"
        }
    }
}

// MARK: Restore Previous Version…

/// A file's versions to choose from, or a folder's history and a time to put it back to.
@MainActor @Observable
final class VersionsModel {
    let drive: JoinedDrive
    private(set) var node: Node
    /// Where it is in the drive.
    private(set) var path = ""
    /// A file's versions, newest first.
    private(set) var versions: [JoinedSnapshot.FileVersion] = []
    /// A folder's changes and what was in it, newest first.
    private(set) var changes: [DriveHistory.Entry] = []
    private(set) var retention = TimeInterval(DriveSettings.defaultRetentionDays) * 86400
    private(set) var busy = false
    private(set) var message: String?
    private(set) var done: String?
    /// For a folder: the time to put it back to.
    var date = Date()
    @ObservationIgnored private var snapshot: JoinedSnapshot

    init(drive: JoinedDrive, node: Node, snapshot: JoinedSnapshot) {
        self.drive = drive
        self.node = node
        self.snapshot = snapshot
        show(snapshot)
    }

    var isFolder: Bool { node.isFolder }
    /// The earliest time history goes back to.
    var earliest: Date { Date().addingTimeInterval(-retention) }

    private func show(_ snapshot: JoinedSnapshot) {
        self.snapshot = snapshot
        if let current = snapshot.tree.nodes[node.id] { node = current }
        path = snapshot.tree.nodes[node.id].map { snapshot.tree.path(of: $0).description } ?? path
        retention = snapshot.home.retention
        if node.isFolder {
            changes = snapshot.changes(in: node.id)
        } else {
            versions = snapshot.versions(of: node.id)
        }
    }

    func reload() async {
        busy = true
        defer { busy = false }
        do {
            show(try await drive.update(snapshot))
        } catch {
            message = String(describing: error)
        }
    }

    /// Puts a file's contents back as they were then, keeping its name and place.
    func restore(_ version: JoinedSnapshot.FileVersion) async {
        let id = node.id
        await run(
            done:
                "Restored the version from \(RestoreReport.when(version.date)). It's the newest version now: to undo this, restore the one before."
        ) { drive, snapshot in
            try await drive.restoreContents(of: id, from: version.version, in: snapshot)
        }
    }

    /// Puts a folder, and everything that was in it, back as it was at `date` (just after the
    /// change made then).
    func restoreFolder(asOf date: Date) async {
        let alert = NSAlert()
        alert.messageText = "Put “\(node.name)” back as it was at \(RestoreReport.when(date))?"
        alert.informativeText =
            "What was in it then comes back as it was, things deleted since included. What was added to it since stays. You can undo this the same way: it's a change like any other."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = node.id
        await run(done: "Put “\(node.name)” back as it was at \(RestoreReport.when(date)).") { drive, snapshot in
            try await drive.restore(id, asOf: date, in: snapshot)
        }
    }

    private func run(
        done text: String, _ body: (JoinedDrive, JoinedSnapshot) async throws -> Drive.RestoreResult
    ) async {
        guard !busy else { return }
        busy = true
        message = nil
        done = nil
        defer { busy = false }
        do {
            let snapshot = try await drive.update(self.snapshot)
            let result = try await body(drive, snapshot)
            if !result.restored.isEmpty {
                done = text
            } else if result.skipped.isEmpty {
                done = "Nothing to do: it's already as it was then."
            }
            message = RestoreReport.problem(result)
            await SharingCoordinator.refreshFinder()
            show(try await drive.update(snapshot))
        } catch {
            message = String(describing: error)
        }
    }

    /// What a version is: how it came about, where, and its size.
    func detail(_ version: JoinedSnapshot.FileVersion) -> String {
        var parts = [Self.label(version.entry.change)]
        if !version.device.isEmpty { parts[0] += " on \(version.device)" }
        parts.append(RestoreReport.size(version.size))
        if version.entry.lost { parts.append("lost a race") }
        if !version.available { parts.append("no longer in history") }
        return parts.joined(separator: " · ")
    }

    static func label(_ change: VersionRecord.Change) -> String {
        switch change {
        case .created: return "Added"
        case .edited: return "Edited"
        case .moved: return "Moved or renamed"
        case .deleted: return "Deleted"
        case .restored: return "Restored"
        case .shared: return "Moved into a share"
        }
    }
}

struct VersionsView: View {
    @State var model: VersionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.isFolder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.node.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check again")
                .disabled(model.busy)
            }
            if model.isFolder {
                folder
            } else {
                file
            }
            if let done = model.done {
                Label(done, systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Callout(text: message)
            }
            Text(
                "The drive keeps \(RestoreReport.days(model.retention)) of history. Restoring is a change like any other, so it can be undone too."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 460)
    }

    // MARK: A file

    private var file: some View {
        List {
            ForEach(model.versions) { version in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(RestoreReport.when(version.date)).monospacedDigit()
                            if version.isCurrent {
                                Text("Current")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.tint.opacity(0.15)))
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(model.detail(version))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !version.isCurrent {
                        Button("Restore") { Task { await model.restore(version) } }
                            .disabled(!version.available || model.busy)
                            .help("Make this the file's contents again, keeping its name and place")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.versions.isEmpty {
                ContentUnavailableView(
                    "No Earlier Versions", systemImage: "clock",
                    description: Text("Its history may be older than the drive keeps."))
            }
        }
    }

    // MARK: A folder

    private var folder: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                HStack {
                    DatePicker(
                        "As it was at", selection: $model.date, in: model.earliest...Date(),
                        displayedComponents: [.date, .hourAndMinute])
                    Spacer()
                    Button("Restore…") { Task { await model.restoreFolder(asOf: model.date) } }
                        .disabled(model.busy)
                }
                .padding(4)
            }
            Text("Or pick a change: the folder goes back as it was just after it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(model.changes) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path?.description ?? "(no longer in history)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Self.detail(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore to Here…") { Task { await model.restoreFolder(asOf: entry.date) } }
                            .disabled(model.busy)
                            .help("Put the folder back as it was just after this change")
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if model.changes.isEmpty {
                    ContentUnavailableView(
                        "No Changes", systemImage: "clock",
                        description: Text("Nothing in it changed in the time the drive keeps history for."))
                }
            }
        }
    }

    private static func detail(_ entry: DriveHistory.Entry) -> String {
        var text = "\(VersionsModel.label(entry.change)) \(RestoreReport.when(entry.date))"
        if !entry.device.isEmpty { text += " on \(entry.device)" }
        if entry.lost { text += " · lost a race" }
        return text
    }
}

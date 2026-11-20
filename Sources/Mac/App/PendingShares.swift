import ATDriveCore
import ATDriveMacSupport
import Observation
import SwiftUI
import os

/// Shares waiting for the signed-in account to accept or decline them (#68), for the menu: checked
/// every few minutes, whenever the menu opens, and after an answer.
@MainActor @Observable
final class PendingSharesModel {
    struct Row: Identifiable, Equatable {
        var share: PendingShare
        /// `@handle` of whoever shared it.
        var from: String
        var id: String { share.id }
    }

    private(set) var rows: [Row] = []
    /// Shares being accepted or declined, by ID.
    private(set) var working: Set<String> = []
    private(set) var message: String?

    /// The joined drive (the app model's, once signed in).
    @ObservationIgnored var makeDrive: (() async -> JoinedDrive?)?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var handles: [String: String] = [:]
    private let logger = Logger(subsystem: Log.subsystem, category: "pending")

    /// How often to check while the menu stays closed.
    static let interval: Duration = .seconds(5 * 60)

    func start() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: PendingSharesModel.interval)
            }
        }
    }

    /// Checks again, unless it just did (the menu opening twice in a row, say). `force`: even so.
    func refresh(force: Bool = false) async {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 10 { return }
        if let refreshing { return await refreshing.value }
        let task = Task { await self.load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        guard let drive = await makeDrive?() else {
            if !rows.isEmpty { rows = [] }
            return
        }
        lastRefresh = Date()
        do {
            var loaded: [Row] = []
            for share in try await drive.pendingShares() {
                loaded.append(Row(share: share, from: await name(share.owner)))
            }
            if loaded != rows { rows = loaded }
        } catch {
            // Keep showing what was there: the next check may work.
            logger.error("checking pending shares failed: \(String(describing: error), privacy: .public)")
        }
    }

    func accept(_ row: Row) async {
        await answer(row) { drive in
            let mount = try await drive.accept(row.share)
            await SharingCoordinator.refreshFinder()
            self.logger.notice("accepted a share as \(mount.name, privacy: .public)")
        }
    }

    func decline(_ row: Row) async {
        await answer(row) { drive in try await drive.decline(row.share) }
    }

    func dismissMessage() { message = nil }

    private func answer(_ row: Row, _ body: @escaping (JoinedDrive) async throws -> Void) async {
        guard let drive = await makeDrive?() else { return }
        working.insert(row.id)
        message = nil
        defer { working.remove(row.id) }
        do {
            try await body(drive)
            rows.removeAll { $0.id == row.id }
        } catch {
            message = String(describing: error)
        }
        await refresh(force: true)
    }

    private func name(_ did: String) async -> String {
        if let known = handles[did] { return known }
        let name = await ShareModel.name(did)
        handles[did] = name
        return name
    }
}

/// The menu's list of shares waiting for you: what each is, who shared it, Add and Decline.
struct PendingSharesSection: View {
    var model: PendingSharesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.rows.count == 1 ? "Shared with you" : "Shared with you (\(model.rows.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.rows) { row in PendingShareRow(row: row, model: model) }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: model.rows.count <= 3)
            if let message = model.message {
                Callout(text: message) { model.dismissMessage() }
            }
        }
    }
}

private struct PendingShareRow: View {
    let row: PendingSharesModel.Row
    var model: PendingSharesModel

    var body: some View {
        let share = row.share
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: share.isFile ? "doc.fill" : "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(share.name ?? "Something")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(share.problem.map { "From \(row.from). Can't open it now: \($0)" } ?? "From \(row.from)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(share.problem ?? "")
            }
            Spacer(minLength: 4)
            if model.working.contains(row.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.decline(row) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Decline: it stops waiting here (its link still opens it)")
                Button("Add") { Task { await model.accept(row) } }
                    .controlSize(.small)
                    .disabled(share.problem != nil)
                    .help("Add it to your drive, read-only, kept up to date")
            }
        }
    }
}

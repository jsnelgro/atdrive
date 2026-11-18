import ATDriveCore
import ATDriveMacSupport
import AppKit
import Observation
import SwiftUI
import os

/// The drive's encryption, as the Settings window shows and changes it: the same steps as
/// `atdrive encryption on` and `off`. Switching ends sharing first, and then converts what's in
/// the drive, which can take a while; that carries on with the window closed.
@MainActor @Observable
final class EncryptionModel {
    /// A switch the user asked for, waiting for them to confirm it.
    struct Switch: Equatable {
        var encrypt: Bool
        /// What stops being shared, in words.
        var endsSharing: [String]
        /// File contents to upload again, in bytes.
        var bytes: Int
    }

    private(set) var status: EncryptionStatus?
    /// Why the status couldn't be read, or the last switch failed.
    private(set) var message: String?
    private(set) var pending: Switch?
    /// While converting: records done, and how many there are.
    private(set) var progress: (done: Int, total: Int)?
    private(set) var working = false
    /// A recovery key just made by turning encryption on, until the user says they've saved it.
    private(set) var recoveryKey: String?

    @ObservationIgnored private weak var app: AppModel?
    private let logger = Logger(subsystem: Log.subsystem, category: "encryption")

    init(app: AppModel) {
        self.app = app
    }

    var isEncrypted: Bool { status?.mode == .encrypted }

    /// What's left to convert, in words: `nil` once there's nothing.
    var unfinished: String? {
        guard let status, !working else { return nil }
        if status.mode == .encrypted, status.pending > 0 || status.converting {
            return "Some of the drive isn't encrypted yet."
        }
        if status.mode == .plain, status.pending > 0 {
            return "Some of the drive is still stored encrypted (readable with the keys it published)."
        }
        return nil
    }

    func refresh() async {
        guard !working, let joined = await app?.joinedDrive() else {
            if !working { status = nil }
            return
        }
        do {
            status = try await joined.home.encryptionStatus()
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    /// The user flipped the toggle: work out what switching means, for them to confirm.
    func request(encrypt: Bool) {
        guard !working, encrypt != isEncrypted else { return }
        message = nil
        Task {
            guard let joined = await app?.joinedDrive() else { return }
            do {
                let snapshot = try await joined.update(nil)
                var ends = try await joined.ownShares(in: snapshot).map { "“\($0.path)” stops being shared." }
                for (id, state) in snapshot.mounts.sorted(by: { $0.key < $1.key }) where state.readOnly {
                    guard let node = snapshot.tree.nodes[id] else { continue }
                    ends.append("“\(snapshot.tree.path(of: node))”, shared with you, is removed from your drive.")
                }
                let bytes = encrypt ? try await joined.home.conversionEstimate(to: .encrypted).pendingBytes : 0
                pending = Switch(encrypt: encrypt, endsSharing: ends, bytes: bytes)
            } catch {
                message = String(describing: error)
            }
        }
    }

    func cancel() {
        pending = nil
    }

    /// The user confirmed `pending`: end sharing, switch, then convert.
    func confirm() {
        guard let change = pending, !working else { return }
        pending = nil
        run { joined in
            if !change.endsSharing.isEmpty { _ = try await joined.endSharing() }
            if change.encrypt {
                self.recoveryKey = try await joined.home.enableEncryption().formatted
            } else {
                try await joined.home.disableEncryption()
            }
            await self.app?.syncNow()
        }
    }

    /// Converts what a switch left (after an interruption, say).
    func finish() {
        run { _ in }
    }

    func savedRecoveryKey() {
        recoveryKey = nil
    }

    /// Runs `step`, then converts the drive, showing progress, then reads the status again.
    private func run(_ step: @escaping @MainActor (JoinedDrive) async throws -> Void) {
        working = true
        message = nil
        Task {
            defer {
                working = false
                progress = nil
            }
            guard let joined = await app?.joinedDrive() else { return }
            do {
                try await step(joined)
                status = try await joined.home.convert { done, total in
                    Task { @MainActor [weak self] in self?.progress = (done, total) }
                }
            } catch {
                logger.error("switching encryption failed: \(String(describing: error), privacy: .public)")
                message = String(describing: error)
            }
            await app?.syncNow()
            working = false
            await refresh()
        }
    }
}

/// The Settings window (ATDrive ▸ Settings…, or from the menu).
struct SettingsView: View {
    @Bindable var app: AppModel
    @Bindable var encryption: EncryptionModel

    var body: some View {
        Form {
            Section("Account") {
                if let handle = app.signedInHandle {
                    LabeledContent("Signed in as", value: "@\(handle)")
                } else {
                    Text("Not signed in. Sign in from ATDrive in the menu bar.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Encryption") {
                if app.signedInHandle == nil {
                    Text("Sign in to change your drive's encryption.").foregroundStyle(.secondary)
                } else if let key = encryption.recoveryKey {
                    RecoveryKeyView(key: key) { encryption.savedRecoveryKey() }
                } else if encryption.status == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading your drive…").foregroundStyle(.secondary)
                    }
                } else {
                    encryptionControls
                }
                if let message = encryption.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: app.signedInHandle) { await encryption.refresh() }
        .alert(
            encryption.pending?.encrypt == true ? "Turn encryption on?" : "Turn encryption off?",
            isPresented: Binding(get: { encryption.pending != nil }, set: { if !$0 { encryption.cancel() } }),
            presenting: encryption.pending
        ) { change in
            Button(change.encrypt ? "Encrypt" : "Turn Off", role: change.encrypt ? nil : .destructive) {
                encryption.confirm()
            }
            Button("Cancel", role: .cancel) { encryption.cancel() }
        } message: { change in
            Text(Self.consequences(of: change))
        }
    }

    @ViewBuilder private var encryptionControls: some View {
        Toggle(
            isOn: Binding(get: { encryption.isEncrypted }, set: { encryption.request(encrypt: $0) })
        ) {
            Text("Encrypt my drive")
            Text(
                encryption.isEncrypted
                    ? "Only your devices can read your files. Each new device has to be approved, and the recovery key is the way back in if you lose them all."
                    : "Whoever runs your server can read your files and their names. There are no keys to keep or lose."
            )
        }
        .disabled(encryption.working || encryption.pending != nil)
        if encryption.working {
            HStack {
                if let progress = encryption.progress, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                    Text("\(progress.done) of \(progress.total)").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(encryption.isEncrypted ? "Turning encryption off…" : "Turning encryption on…")
                        .foregroundStyle(.secondary)
                }
            }
            Text("This carries on if you close this window. Keep ATDrive running until it's done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let unfinished = encryption.unfinished {
            HStack {
                Text(unfinished).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(encryption.isEncrypted ? "Finish Encrypting" : "Finish Decrypting") { encryption.finish() }
            }
        }
    }

    static func consequences(of change: EncryptionModel.Switch) -> String {
        var lines: [String] = []
        if change.encrypt {
            lines.append(
                "Every file is uploaded again, encrypted"
                    + (change.bytes > 0
                        ? " (\(ByteCountFormatter.string(fromByteCount: Int64(change.bytes), countStyle: .file)))" : "")
                    + ". If it's interrupted, it picks up where it stopped.")
            lines.append(
                "You get a recovery key to keep safe. Lose it and every device that has the drive's keys, and nobody can read the drive again."
            )
            lines.append("Your other devices must be approved again before they can use the drive.")
            lines.append(
                "Whoever runs your server could read what's there until now. This protects it from here on, not copies already made."
            )
        } else {
            lines.append(
                "Whoever runs your server will be able to read everything in the drive, history included. This can't be taken back for what's already there."
            )
            lines.append(
                "The drive's devices and recovery key are forgotten: any device signed in to your account can use the drive."
            )
        }
        if !change.endsSharing.isEmpty {
            lines.append("Switching ends sharing. Share again afterwards:")
            lines += change.endsSharing.map { "  • \($0)" }
        }
        return lines.joined(separator: "\n\n")
    }
}

/// A recovery key, shown once, until the user says they've saved it.
struct RecoveryKeyView: View {
    let key: String
    let saved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your drive's recovery key").font(.headline)
            Text(key)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Write it down, or keep it in a password manager, now: it's shown only this once. With it, "
                    + "any device you sign in on can open the drive. If you lose every device that has the "
                    + "drive's keys and this key too, nobody can read your files again: not you, and not "
                    + "whoever runs your server."
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
                Spacer()
                Button("I've Saved It", action: saved)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

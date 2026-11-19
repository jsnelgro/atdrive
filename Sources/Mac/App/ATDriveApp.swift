import ATDriveCore
import AppKit
import SwiftUI

/// Menu-bar-only app (no Dock icon: `LSUIElement` in Info.plist). Your files live in Finder,
/// under Locations; this is just for signing in and a few shortcuts.
@main
struct ATDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var encryption: EncryptionModel

    init() {
        let model = AppModel()
        model.start()
        SharingCoordinator.shared.makeDrive = { [weak model] in await model?.joinedDrive() }
        SharingCoordinator.shared.start()
        _model = State(initialValue: model)
        _encryption = State(initialValue: EncryptionModel(app: model))
    }

    var body: some Scene {
        MenuBarExtra("ATDrive", systemImage: "externaldrive.badge.icloud") {
            MenuContent(model: model, encryption: encryption)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(app: model, encryption: encryption)
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    var encryption: EncryptionModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                switch model.state {
                case .signedOut: signInForm
                case .signingIn: waitingForBrowser
                case .openingDrive: openingDrive
                case .choosingEncryption: choosingEncryption
                case .showingRecoveryKey(_, let key): recoveryKey(key)
                case .needsKeys: needsKeys
                case .signedIn(let handle): account(handle)
                }
                if let message = model.message {
                    Callout(text: message) { model.dismissMessage() }
                }
            }
            .padding(12)

            if case .signedIn = model.state {
                Divider()
                VStack(spacing: 0) {
                    MenuRow("Open in Finder", systemImage: "folder") { Task { await model.showInFinder() } }
                    if model.config.appsEnabled {
                        MenuRow("Open Apps in Finder", systemImage: "square.grid.2x2") {
                            Task { await model.showAppsInFinder() }
                        }
                    }
                    MenuRow("Add Shared Link…", systemImage: "link.badge.plus") {
                        SharingCoordinator.shared.askForLink()
                    }
                    MenuRow("Check for Changes", systemImage: "arrow.clockwise") { Task { await model.syncNow() } }
                }
                .padding(6)
            }

            Divider()
            VStack(spacing: 0) {
                MenuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                    // A menu-bar app isn't active, so its windows would open behind others.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                MenuRow("Install Command-Line Tool…", systemImage: "terminal") {
                    CommandLineTool.showInstructions()
                }
                MenuRow("Quit ATDrive", systemImage: "power", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    // MARK: Signed in

    private func account(_ handle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(.tint.opacity(0.15))
                    Text(handle.first.map { String($0).uppercased() } ?? "?")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(handle)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    status
                }
            }
            if encryption.working {
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = encryption.progress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(converting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var status: some View {
        let encrypted = (encryption.status?.mode ?? model.driveMode) == .encrypted
        var parts = [encrypted ? "Encrypted" : "Not encrypted"]
        if let checked = model.lastChecked {
            parts.append("checked \(checked.formatted(date: .omitted, time: .shortened))")
        }
        return Label(parts.joined(separator: " · "), systemImage: encrypted ? "lock.fill" : "lock.open")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private var converting: String {
        let verb = encryption.isEncrypted ? "Encrypting" : "Decrypting"
        guard let progress = encryption.progress, progress.total > 0 else { return "\(verb) your drive…" }
        return "\(verb) your drive: \(progress.done) of \(progress.total)"
    }

    // MARK: Signing in

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(
                title: "ATDrive", systemImage: "externaldrive.badge.icloud",
                detail: "Your files, kept in your atproto account and in Finder.")
            TextField("Handle", text: $model.handle, prompt: Text("alice.bsky.social"))
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .onSubmit { model.signIn() }
            Button {
                model.signIn()
            } label: {
                Text("Sign In").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.handle.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("You'll approve ATDrive on your account's sign-in page, in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var waitingForBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(
                title: "Continue in your browser", systemImage: "safari",
                detail: "Approve ATDrive on your account's sign-in page, then come back here.")
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
            }
        }
    }

    private var openingDrive: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Opening your drive…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    // MARK: A new drive

    /// The account has no drive yet: encrypt it or not.
    private var choosingEncryption: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(
                title: "Set up your drive", systemImage: "externaldrive.badge.plus",
                detail: "Choose whether to encrypt it. You can change this later in Settings.")
            choice(
                "Not encrypted", systemImage: "lock.open",
                detail: "Simplest. Whoever runs your server can read your files. No keys to keep or lose."
            ) { model.createDrive(encrypted: false) }
            choice(
                "Encrypted", systemImage: "lock.fill",
                detail: "Only your devices can read your files. You keep a recovery key, and approve new devices."
            ) { model.createDrive(encrypted: true) }
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Making your drive…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out") { Task { await model.signOut() } }
                    .buttonStyle(.link)
                    .disabled(model.busy)
            }
        }
    }

    private func choice(
        _ title: String, systemImage: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .buttonStyle(ChoiceCardStyle())
        .disabled(model.busy)
    }

    /// A new drive's recovery key, until the user says they've saved it. It stays here if the
    /// menu closes.
    private func recoveryKey(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(
                title: "Your drive is encrypted", systemImage: "lock.fill",
                detail: "Only your devices can read it. One more thing:")
            RecoveryKeyView(key: key) { model.savedRecoveryKey() }
        }
    }

    // MARK: An encrypted drive this Mac can't open yet

    /// This Mac doesn't have the drive's keys: approval from another device, or the recovery key.
    private var needsKeys: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(
                title: "Unlock your drive", systemImage: "lock.fill",
                detail: "Your drive is encrypted, and this Mac doesn't have its keys yet.")
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let arrived = model.arrived {
                        Text("“\(arrived.sender.name)” approved this Mac. Its code:")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(arrived.code)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Is it the same code “\(arrived.sender.name)” showed? If not, someone swapped in a key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Doesn't Match") { model.confirmArrived(matches: false) }
                            Spacer()
                            Button("Same Code") { model.confirmArrived(matches: true) }
                                .keyboardShortcut(.defaultAction)
                        }
                    } else if model.waitingForApproval {
                        Text("On a device that has the keys, run:")
                            .font(.caption)
                        Text("atdrive devices approve \(model.deviceName)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("It shows a code. This Mac's code with each of your devices:")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.pairingCodes) { line in
                            HStack {
                                Text(line.name)
                                Spacer()
                                Text(line.code).font(.system(.body, design: .monospaced))
                            }
                        }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for approval…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Approve it from a device that has the keys.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Approve from Another Device…") { model.waitForApproval() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or enter your recovery key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("Recovery key", text: $model.recoveryKeyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.unlockWithRecoveryKey() }
                    Button("Unlock") { model.unlockWithRecoveryKey() }
                        .disabled(model.recoveryKeyText.isEmpty || model.busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            HStack {
                Spacer()
                Button("Sign Out") { Task { await model.signOut() } }
                    .buttonStyle(.link)
                    .disabled(model.busy)
            }
        }
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .signedOut: signInForm
            case .signingIn: waitingForBrowser
            case .openingDrive: openingDrive
            case .choosingEncryption: choosingEncryption
            case .showingRecoveryKey(_, let key): recoveryKey(key)
            case .needsKeys: needsKeys
            case .signedIn(let handle): signedIn(as: handle)
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Settings…") {
                    // A menu-bar app isn't active, so its windows would open behind others.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit ATDrive") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to ATDrive").font(.headline)
            Text("Enter your handle. You'll approve access on your account's own sign-in page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("alice.example.com", text: $model.handle)
                .textContentType(.username)
                .onSubmit { model.signIn() }
            Button("Sign In with Browser") { model.signIn() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.handle.isEmpty)
        }
    }

    private var waitingForBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish signing in in your browser").font(.headline)
            Text("Approve ATDrive there, then come back here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
            }
        }
    }

    private var openingDrive: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Opening your drive…")
        }
    }

    /// The account has no drive yet: encrypt it or not.
    private var choosingEncryption: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up your drive").font(.headline)
            Text("Choose whether to encrypt it. You can change this later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            choice(
                "Not Encrypted", systemImage: "externaldrive",
                detail: "Simplest. Whoever runs your server can read your files. There are no keys to keep or lose."
            ) { model.createDrive(encrypted: false) }
            choice(
                "Encrypted", systemImage: "lock",
                detail:
                    "Only your devices can read your files. You get a recovery key to keep safe, and approve each new device."
            ) { model.createDrive(encrypted: true) }
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Making your drive…").font(.caption)
                }
            }
            Button("Sign Out") { Task { await model.signOut() } }
                .disabled(model.busy)
        }
    }

    private func choice(
        _ title: String, systemImage: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage).font(.title2).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(model.busy)
    }

    /// A new drive's recovery key, until the user says they've saved it. It stays here if the
    /// menu closes.
    private func recoveryKey(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your drive is encrypted: only your devices can read it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RecoveryKeyView(key: key) { model.savedRecoveryKey() }
        }
    }

    /// This Mac doesn't have the drive's keys: approval from another device, or the recovery key.
    private var needsKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Mac needs your drive's keys").font(.headline)
            Text(
                "Your drive is encrypted. Approve this Mac from a device that has its keys, or enter the recovery key."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let arrived = model.arrived {
                Text("“\(arrived.sender.name)” approved this Mac. Its code:")
                    .fixedSize(horizontal: false, vertical: true)
                Text(arrived.code).font(.system(.title3, design: .monospaced))
                Text(
                    "Is it the same as “\(arrived.sender.name)” showed? If not, something swapped in a key of its own."
                )
                .font(.caption)
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
                Text("It shows a code. This Mac's code with each of them:")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.pairingCodes) { line in
                    HStack {
                        Text(line.name)
                        Spacer()
                        Text(line.code).font(.system(.body, design: .monospaced))
                    }
                }
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…").font(.caption)
                }
            } else {
                Button("Approve from Another Device…") { model.waitForApproval() }
            }
            Divider()
            SecureField("Recovery key", text: $model.recoveryKeyText)
                .onSubmit { model.unlockWithRecoveryKey() }
            Button("Unlock with Recovery Key") { model.unlockWithRecoveryKey() }
                .disabled(model.recoveryKeyText.isEmpty)
            Button("Sign Out") { Task { await model.signOut() } }
                .disabled(model.busy)
        }
    }

    private func signedIn(as handle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("@\(handle)", systemImage: "person.crop.circle").font(.headline)
            if encryption.working {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(
                        encryption.progress.map { "Converting your drive: \($0.done) of \($0.total)" }
                            ?? "Converting your drive…"
                    )
                    .font(.caption)
                }
            }
            Button("Show in Finder") { Task { await model.showInFinder() } }
            Button("Check for Changes") { Task { await model.syncNow() } }
            Button("Add Shared Link…") { SharingCoordinator.shared.askForLink() }
            Button("Sign Out") { Task { await model.signOut() } }
                .disabled(model.busy)
        }
    }
}

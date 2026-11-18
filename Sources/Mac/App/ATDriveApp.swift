import ATDriveCore
import AppKit
import SwiftUI

/// Menu-bar-only app (no Dock icon: `LSUIElement` in Info.plist). Your files live in Finder,
/// under Locations; this is just for signing in and a few shortcuts.
@main
struct ATDriveApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra("ATDrive", systemImage: "externaldrive.badge.icloud") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .signedOut: signInForm
            case .signingIn: waitingForBrowser
            case .openingDrive: openingDrive
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
            Button("Quit ATDrive") { NSApplication.shared.terminate(nil) }
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

    /// A new drive's recovery key, until the user says they've saved it. It stays here if the
    /// menu closes.
    private func recoveryKey(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your drive's recovery key").font(.headline)
            Text("Your drive is encrypted: only your devices can read it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Button("I've Saved It") { model.savedRecoveryKey() }
                    .keyboardShortcut(.defaultAction)
            }
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
            Button("Show in Finder") { Task { await model.showInFinder() } }
            Button("Check for Changes") { Task { await model.syncNow() } }
            Button("Sign Out") { Task { await model.signOut() } }
                .disabled(model.busy)
        }
    }
}

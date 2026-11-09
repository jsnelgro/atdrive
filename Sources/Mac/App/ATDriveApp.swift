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
            Text("Your atproto handle and an app password. The password isn't stored.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("alice.example.com", text: $model.handle)
                .textContentType(.username)
            SecureField("App password", text: $model.password)
                .onSubmit { Task { await model.signIn() } }
            Button(model.busy ? "Signing in…" : "Sign In") {
                Task { await model.signIn() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy || model.handle.isEmpty || model.password.isEmpty)
        }
    }

    private func signedIn(as handle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("@\(handle)", systemImage: "person.crop.circle").font(.headline)
            Button("Open in Finder") { Task { await model.openInFinder() } }
            Button("Check for Changes") { Task { await model.syncNow() } }
            Button("Sign Out") { Task { await model.signOut() } }
                .disabled(model.busy)
        }
    }
}

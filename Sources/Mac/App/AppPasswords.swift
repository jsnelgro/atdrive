import ATDriveCore
import ATDriveMacSupport
import AppKit
import Observation
import SwiftUI

/// State for the App Passwords window. Unlocking with the account password starts a temporary
/// full-access session (the PDS won't manage app passwords with ATDrive's OAuth sign-in), which
/// ends when the window closes. The password isn't kept.
@MainActor @Observable
final class AppPasswordsModel {
    private(set) var handle = ""
    private(set) var unlocked = false
    private(set) var busy = false
    private(set) var passwords: [AppPassword] = []
    /// The one just created: its password is shown once, then forgotten when the window closes.
    private(set) var created: NewAppPassword?
    private(set) var error: String?

    @ObservationIgnored private var manager: AppPasswordManager?

    func loadAccount() {
        handle = (try? AppGroup.sessionStore()?.load())?.handle ?? ""
    }

    func unlock(password: String) async {
        guard let account = try? AppGroup.sessionStore()?.load() else {
            error = "Sign in to ATDrive first."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let manager = try await AppPasswordManager.unlock(account: account, password: password)
            self.manager = manager
            passwords = try await manager.list()
            unlocked = true
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Returns whether it worked (so the name field can be cleared).
    func create(name: String) async -> Bool {
        guard let manager else { return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            created = try await manager.create(name: name)
            passwords = try await manager.list()
            return true
        } catch {
            self.error = String(describing: error)
            return false
        }
    }

    func delete(_ name: String) async {
        guard let manager else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await manager.revoke(name: name)
            passwords.removeAll { $0.name == name }
            if created?.name == name { created = nil }
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Ends the temporary session and forgets everything shown.
    func lock() async {
        let manager = manager
        self.manager = nil
        unlocked = false
        passwords = []
        created = nil
        error = nil
        await manager?.lock()
    }
}

/// The window itself: AppKit, so it opens only when asked (a menu-bar-only app has no other
/// windows) and locks when closed.
@MainActor
final class AppPasswordsWindow: NSObject, NSWindowDelegate {
    private let model: AppPasswordsModel
    private var window: NSWindow?

    init(model: AppPasswordsModel) {
        self.model = model
    }

    func show() {
        model.loadAccount()
        if window == nil {
            let hosting = NSHostingController(rootView: AppPasswordsView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "App Passwords"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Task { await model.lock() }
    }
}

struct AppPasswordsView: View {
    @Bindable var model: AppPasswordsModel
    @State private var password = ""
    @State private var newName = ""
    @State private var pendingDeletion: AppPassword?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "App passwords let scripts and other tools sign in as you, for example `atdrive login --app-password`."
            )
            .fixedSize(horizontal: false, vertical: true)
            if model.unlocked { manageSection } else { unlockSection }
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { password in
            Button("Delete", role: .destructive) { Task { await model.delete(password.name) } }
        } message: { _ in
            Text(
                "Anything signed in with it is signed out within about 2 hours, when its current access token expires. The server can't cut that short."
            )
        }
    }

    private var unlockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Managing them needs your account password, because your PDS doesn't allow it with ATDrive's sign-in. It's used only while this window is open and isn't saved."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Account password for @\(model.handle)", text: $password)
                    .onSubmit(submitPassword)
                Button("Unlock", action: submitPassword)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.busy)
            }
        }
    }

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let created = model.created {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New app password “\(created.name)”").font(.headline)
                        HStack {
                            Text(created.password)
                                .font(.system(.title3, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(created.password, forType: .string)
                            }
                        }
                        Text("Copy it now: it won't be shown again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }

            if model.passwords.isEmpty {
                Text("No app passwords yet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.passwords) { password in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(password.name)
                                if let date = password.createdDate {
                                    Text("Created \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Delete", role: .destructive) { pendingDeletion = password }
                                .disabled(model.busy)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }

            HStack {
                TextField("New app password name, e.g. laptop-cli", text: $newName)
                    .onSubmit(create)
                Button("Create", action: create)
                    .disabled(trimmedName.isEmpty || model.busy)
            }
        }
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    private func submitPassword() {
        let typed = password
        password = ""
        guard !typed.isEmpty else { return }
        Task { await model.unlock(password: typed) }
    }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        Task {
            if await model.create(name: name) { newName = "" }
        }
    }
}

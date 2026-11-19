import ATDriveCore
import ATDriveMacSupport
import AppKit
import Observation
import SwiftUI

/// The spaces added to the apps view by address, as the Settings window shows and changes them:
/// the same as `atdrive apps add` and `remove`, for all the account's devices.
@MainActor @Observable
final class AddedSpacesModel {
    private(set) var spaces: [String] = []
    private(set) var message: String?
    private(set) var working = false
    var address = ""

    @ObservationIgnored private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    func refresh() async {
        guard let apps = await app?.appData() else {
            spaces = []
            return
        }
        do {
            spaces = try await apps.addedSpaces()
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    func add() {
        let address = address
        change { apps in
            try await apps.add(address)
            self.address = ""
        }
    }

    func remove(_ space: String) {
        change { apps in try await apps.remove(space) }
    }

    private func change(_ step: @escaping @MainActor (AppData) async throws -> Void) {
        guard !working else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            guard let apps = await app?.appData() else { return }
            do {
                try await step(apps)
                await app?.appsChanged()
            } catch {
                message = String(describing: error)
            }
            await refresh()
        }
    }
}

/// Settings ▸ Other Apps: the apps location (on or off), Spotlight, and spaces added by address.
struct AppsSection: View {
    @Bindable var app: AppModel
    @State private var added: AddedSpacesModel

    init(app: AppModel) {
        self.app = app
        _added = State(initialValue: AddedSpacesModel(app: app))
    }

    var body: some View {
        Section("Other Apps") {
            Toggle(isOn: Binding(get: { app.config.appsEnabled }, set: { app.setAppsEnabled($0) })) {
                Text("Show data from my other apps")
                Text(
                    "What other atproto apps keep in your spaces, and spaces people share with you, read-only, in Finder under Apps. It downloads other people's data to this Mac."
                )
            }
            if app.config.appsEnabled {
                if OAuthLogin.appsNeedNewSignIn {
                    Text("This needs access to all your spaces: sign out and in again to grant it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { app.config.appsSpotlight }, set: { app.setAppsSpotlight($0) })) {
                    Text("Show in Spotlight searches")
                    Text("Off, what's in Apps (other people's data included) stays out of search results.")
                }
                if app.signedInHandle != nil { addedSpaces }
            }
        }
        .task(id: "\(app.signedInHandle ?? "")\(app.config.appsEnabled)") {
            if app.config.appsEnabled { await added.refresh() }
        }
    }

    @ViewBuilder private var addedSpaces: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Spaces shared with you that you've never written to don't show up by themselves. Paste one's address to add it, on all your devices."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("at://alice.example.com/space/…", text: $added.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { added.add() }
                Button("Add") { added.add() }
                    .disabled(added.address.trimmingCharacters(in: .whitespaces).isEmpty || added.working)
            }
            ForEach(added.spaces, id: \.self) { space in
                HStack {
                    Text(space)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Remove") { added.remove(space) }
                        .disabled(added.working)
                }
            }
            if let message = added.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

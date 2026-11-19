import ATDriveCore
import ATDriveMacSupport
import AppKit
import Observation
import SwiftUI

/// The spaces added to the spaces view by address, as the Settings window shows and changes
/// them: the same as `atdrive spaces add` and `remove`, for all the account's devices.
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
        guard let data = await app?.spaceData() else {
            spaces = []
            return
        }
        do {
            spaces = try await data.addedSpaces()
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    func add() {
        let address = address
        change { data in
            try await data.add(address)
            self.address = ""
        }
    }

    func remove(_ space: String) {
        change { data in try await data.remove(space) }
    }

    private func change(_ step: @escaping @MainActor (SpaceData) async throws -> Void) {
        guard !working else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            guard let data = await app?.spaceData() else { return }
            do {
                try await step(data)
                await app?.spacesChanged()
            } catch {
                message = String(describing: error)
            }
            await refresh()
        }
    }
}

/// Settings ▸ Spaces: the Spaces location (on or off), Spotlight, and spaces added by address.
struct SpacesSection: View {
    @Bindable var app: AppModel
    @State private var added: AddedSpacesModel

    init(app: AppModel) {
        self.app = app
        _added = State(initialValue: AddedSpacesModel(app: app))
    }

    var body: some View {
        Section("Spaces") {
            Toggle(isOn: Binding(get: { app.config.spacesEnabled }, set: { app.setSpacesEnabled($0) })) {
                Text("Show what's in my spaces")
                Text(
                    "What other atproto apps keep in your spaces, and spaces people share with you, read-only, in Finder under Spaces. It downloads other people's data to this Mac."
                )
            }
            if app.config.spacesEnabled {
                if OAuthLogin.spacesNeedNewSignIn {
                    Text("This needs access to all your spaces: sign out and in again to grant it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { app.config.spacesSpotlight }, set: { app.setSpacesSpotlight($0) })) {
                    Text("Show in Spotlight searches")
                    Text("Off, what's in Spaces (other people's data included) stays out of search results.")
                }
                if app.signedInHandle != nil { addedSpaces }
            }
        }
        .task(id: "\(app.signedInHandle ?? "")\(app.config.spacesEnabled)") {
            if app.config.spacesEnabled { await added.refresh() }
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

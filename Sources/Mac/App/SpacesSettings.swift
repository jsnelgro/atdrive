import ATDriveCore
import ATDriveMacSupport
import AppKit
import Observation
import SwiftUI

/// The spaces in the Spaces folder, as the Settings window lists them: what `atdrive spaces`
/// prints.
@MainActor @Observable
final class SpacesListModel {
    struct Row: Identifiable, Equatable {
        var id: String { uri }
        var uri: String
        /// As it would be written in config.toml: the owner by handle where known.
        var address: String
        /// Where it is in the drive.
        var path: String
        var included: Bool
        var problem: String?
    }

    /// An address in config.toml that can't be used, and why.
    struct Unusable: Identifiable, Equatable {
        var id: String { address }
        var address: String
        var why: String
    }

    private(set) var rows: [Row] = []
    private(set) var unusable: [Unusable] = []
    private(set) var problem: String?
    private(set) var loading = false

    @ObservationIgnored private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    func refresh() async {
        guard let joined = await app?.joinedDrive() else {
            rows = []
            return
        }
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await joined.update(nil)
            problem = snapshot.spaces?.problem
            guard let read = snapshot.spaces?.snapshot else {
                rows = []
                return
            }
            let tree = snapshot.tree
            func address(_ uri: String) -> String {
                guard let parts = XRPCClient.spaceParts(uri) else { return uri }
                return "at://\(read.handles[parts.authority] ?? parts.authority)/space/\(parts.type)/\(parts.key)"
            }
            rows = read.spaces.values.map { space in
                let node = tree.nodes[NodeID.join(SpacesFolder.id, "s|\(space.uri)")]
                return Row(
                    uri: space.uri, address: address(space.uri),
                    path: node.map { tree.path(of: $0).description } ?? space.uri, included: space.included,
                    problem: space.problem?.description)
            }
            .sorted { $0.path < $1.path }
            unusable = read.unusable.map { Unusable(address: $0.key, why: $0.value) }.sorted { $0.address < $1.address }
        } catch {
            problem = String(describing: error)
        }
    }
}

/// Settings ▸ Spaces: whether the Spaces folder is there, its name, Spotlight, and which spaces
/// it shows. Everything here is config.toml's `[spaces]`, which can be edited by hand instead.
struct SpacesSection: View {
    @Bindable var app: AppModel
    @State private var list: SpacesListModel
    @State private var folder = ""
    @State private var address = ""

    init(app: AppModel) {
        self.app = app
        _list = State(initialValue: SpacesListModel(app: app))
    }

    var body: some View {
        Section("Spaces") {
            Toggle(
                isOn: Binding(
                    get: { app.config.spacesEnabled }, set: { on in app.updateConfig { $0.spacesEnabled = on } })
            ) {
                Text("Show my spaces")
                Text(
                    "What other atproto apps keep in your spaces, and spaces people share with you, in a read-only folder in your drive. It downloads other people's data to this Mac."
                )
            }
            if app.config.spacesEnabled {
                if OAuthLogin.spacesNeedNewSignIn {
                    Text("This needs access to all your spaces: sign out and in again to grant it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Folder name") {
                    TextField("Spaces", text: $folder)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit { saveFolder() }
                }
                Toggle(
                    isOn: Binding(
                        get: { app.config.spacesSpotlight }, set: { on in app.updateConfig { $0.spacesSpotlight = on } }
                    )
                ) {
                    Text("Show in Spotlight searches")
                    Text("Off, what's in it (other people's data included) stays out of search results.")
                }
                if app.signedInHandle != nil { spaces }
            }
        }
        .onAppear { folder = app.config.spacesFolder }
        .onChange(of: app.config.spacesFolder) { _, name in folder = name }
        .task(id: "\(app.signedInHandle ?? "")\(app.config.spaces.map { "\($0)" } ?? "off")") {
            if app.config.spacesEnabled { await list.refresh() }
        }
    }

    private func saveFolder() {
        let name = folder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else {
            folder = app.config.spacesFolder
            return
        }
        app.updateConfig { $0.spacesFolder = name }
    }

    @ViewBuilder private var spaces: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = list.problem {
                note("Couldn't read your spaces: \(problem)", color: .red)
            }
            ForEach(list.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.path)
                        Text(row.address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let problem = row.problem {
                            Text("Can't be read: \(problem)").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(row.included ? "Remove" : "Hide") {
                        app.updateConfig { config in
                            if row.included {
                                config.spacesInclude.removeAll { $0 == row.address || $0 == row.uri }
                            } else {
                                config.spacesExclude.append(row.address)
                            }
                        }
                    }
                }
            }
            if list.rows.isEmpty, !list.loading, list.problem == nil {
                note("No spaces yet but ATDrive's own.", color: .secondary)
            }
            if !app.config.spacesExclude.isEmpty {
                // As config.toml has them (spaces.exclude).
                Text("Hidden").font(.caption.bold()).padding(.top, 4)
                ForEach(app.config.spacesExclude, id: \.self) { excluded in
                    HStack {
                        Text(excluded).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show") {
                            app.updateConfig { config in config.spacesExclude.removeAll { $0 == excluded } }
                        }
                    }
                }
            }
            ForEach(list.unusable) { unusable in
                note("\(unusable.address) isn't used: \(unusable.why)", color: .red)
            }
            note(
                "A space shared with you that you've never written to doesn't show up by itself. Paste its address to include it.",
                color: .secondary)
            HStack {
                TextField("at://alice.example.com/space/…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(include)
                Button("Include", action: include)
                    .disabled(!SpacesSettings.isAddress(address.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    private func include() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard SpacesSettings.isAddress(text) else { return }
        app.updateConfig { config in
            if !config.spacesInclude.contains(text) { config.spacesInclude.append(text) }
            config.spacesExclude.removeAll { $0 == text }
        }
        address = ""
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

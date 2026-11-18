import ATDriveCore
import ATDriveMacSupport
import AppKit
import Observation
import SwiftUI
import os

/// Sharing in the menu-bar app: Finder's actions (handed over by the extension as a
/// `SharingRequest`), `atdrive://` links, and the windows for both: Share… (who has access, the
/// link) and Open Link (what's shared, from whom, Add to My Drive or Download…).
@MainActor
final class SharingCoordinator {
    static let shared = SharingCoordinator()

    private var windows: [NSWindow] = []
    private let logger = Logger(subsystem: Log.subsystem, category: "sharing")
    /// Makes the joined drive (the app model's, once signed in).
    var makeDrive: (() async -> JoinedDrive?)?

    /// Listens for the extension's requests.
    func start() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, _, _, _, _ in Task { @MainActor in SharingCoordinator.shared.handleRequest() } },
            SharingRequest.notification as CFString, nil, .deliverImmediately)
        handleRequest()  // one written while the app wasn't running
    }

    func handleRequest() {
        guard let request = SharingRequest.take() else { return }
        Task { await handle(request) }
    }

    private func handle(_ request: SharingRequest) async {
        guard let drive = await makeDrive?() else { return alert("Sign in to ATDrive first.") }
        do {
            let snapshot = try await drive.update(nil)
            guard let node = snapshot.tree.nodes[request.item] ?? snapshot.home.tree.nodes[request.item] else {
                return alert("That item isn't in your drive any more.")
            }
            switch request.action {
            case .share:
                show(ShareView(model: ShareModel(drive: drive, node: node)), title: "Share “\(node.name)”")
            case .copyLink:
                let link = try await drive.link(of: node) ?? node.record.mount.map { ShareLinkAddress(space: $0.space) }
                guard let link else { return alert("“\(node.name)” isn't shared.") }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.description, forType: .string)
            case .stopSharing:
                guard
                    confirm(
                        "Stop sharing “\(node.name)” with everyone?",
                        detail:
                            "Everyone you shared it with loses it, and its link stops working. It stays in your drive, an ordinary \(node.isFolder ? "folder" : "file") again. What people already downloaded stays theirs."
                    )
                else { return }
                try await drive.unshare(node)
                await Self.refreshFinder()
            }
        } catch {
            logger.error("sharing request failed: \(String(describing: error), privacy: .public)")
            alert(String(describing: error))
        }
    }

    /// Finder shows sharing changes (badges, a share's new form) now, not at the next poll.
    static func refreshFinder() async {
        guard let manager = DriveDomain.manager else { return }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    /// An `atdrive://` link was opened.
    func open(_ url: URL) {
        Task {
            guard let drive = await makeDrive?() else { return alert("Sign in to ATDrive first.") }
            do {
                let link = try ShareLinkAddress(parsing: url.absoluteString)
                if drive.isOwn(link) {
                    // Yours already: nothing to add or download.
                    let path = (try? await drive.path(of: link)).flatMap { $0 }
                    let place = path.map { ", at \($0)" } ?? ""
                    return alert(
                        "This is your own share",
                        detail: "It's already in your drive\(place). Links you share are for other people to open.")
                }
                let model = OpenLinkModel(drive: drive, link: link)
                show(OpenLinkView(model: model), title: "Shared with you")
                await model.load()
            } catch {
                alert(String(describing: error))
            }
        }
    }

    /// "Add Shared Link…": a field to paste a link into.
    func askForLink() {
        show(
            PasteLinkView { [weak self] text in
                guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                self?.open(url)
            }, title: "Add Shared Link")
    }

    private func show<Content: View>(_ view: Content, title: String) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.frame(minWidth: 380)))
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windows.removeAll { !$0.isVisible && $0 !== window }
    }

    private func alert(_ text: String, detail: String? = nil) {
        let alert = NSAlert()
        alert.messageText = text
        if let detail { alert.informativeText = detail }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func confirm(_ text: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = detail
        alert.addButton(withTitle: "Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Opens `atdrive://` links (`CFBundleURLTypes` in the app's Info.plist).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "atdrive" {
            Task { @MainActor in SharingCoordinator.shared.open(url) }
        }
    }
}

// MARK: Share…

@MainActor @Observable
final class ShareModel {
    struct Person: Identifiable, Equatable {
        var did: String
        var name: String
        var notes: [String]
        var id: String { did }
    }

    let drive: JoinedDrive
    private(set) var node: Node
    private(set) var people: [Person] = []
    private(set) var link: ShareLinkAddress?
    private(set) var linkOn = false
    private(set) var busy = false
    private(set) var message: String?
    var newPerson = ""
    var plain = false
    /// Warnings to confirm before adding someone.
    var pendingWarnings: [String] = []
    private var pendingDIDs: [String] = []

    init(drive: JoinedDrive, node: Node) {
        self.drive = drive
        self.node = node
    }

    var isShared: Bool { node.isMount }
    var isMine: Bool { node.record.mount.map { $0.owner == drive.owner } ?? true }
    var driveIsEncrypted: Bool { drive.mode == .encrypted }

    func load() async {
        guard node.isMount, isMine else { return }
        await run {
            let members = try await self.drive.members(of: self.node)
            var people: [Person] = []
            for member in members {
                var notes: [String] = []
                if member.verified { notes.append("verified") }
                if member.protected == false { notes.append("their drive isn't encrypted") }
                if member.keyChanged { notes.append("their key changed") }
                people.append(Person(did: member.did, name: await Self.name(member.did), notes: notes))
            }
            self.people = people
            self.link = try await self.drive.link(of: self.node)
            self.linkOn = self.link != nil
        }
    }

    func share() async {
        await run {
            self.node = try await self.drive.share(self.node, plain: self.plain)
        }
        await load()
    }

    func add() async {
        let text = newPerson.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        await run {
            let did = text.hasPrefix("did:") ? text : try await IdentityResolver().resolve(text).did
            let warnings = try await self.drive.memberWarnings([did], for: self.node)
            if warnings.isEmpty {
                try await self.drive.addMembers([did], to: self.node)
                self.newPerson = ""
            } else {
                self.pendingDIDs = [did]
                self.pendingWarnings = warnings.map(\.description)
            }
        }
        await load()
    }

    /// Adds who `add` warned about, now that the user said so.
    func addAnyway() async {
        let dids = pendingDIDs
        pendingDIDs = []
        pendingWarnings = []
        await run {
            try await self.drive.addMembers(dids, to: self.node, allowingChangedKeys: true)
            self.newPerson = ""
        }
        await load()
    }

    func cancelAdd() {
        pendingDIDs = []
        pendingWarnings = []
    }

    func remove(_ person: Person) async {
        await run { try await self.drive.removeMembers([person.did], from: self.node) }
        await load()
    }

    func setLink(_ on: Bool) async {
        await run {
            if on {
                self.link = try await self.drive.turnLinkOn(self.node)
            } else {
                try await self.drive.turnLinkOff(self.node)
                self.link = nil
            }
            self.linkOn = on
        }
    }

    func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.description, forType: .string)
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await body()
            await SharingCoordinator.refreshFinder()
        } catch {
            message = String(describing: error)
        }
    }

    static func name(_ did: String) async -> String {
        (try? await IdentityResolver().resolve(did).handle).map { "@\($0)" } ?? did
    }
}

struct ShareView: View {
    @State var model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isShared {
                notShared
            } else if !model.isMine {
                Text("Shared with you, read-only. Only its owner can change who has it.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                people
                Divider()
                link
            }
            if !model.pendingWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.pendingWarnings, id: \.self) { Text($0).font(.caption) }
                    HStack {
                        Button("Share Anyway") { Task { await model.addAnyway() } }
                        Button("Cancel") { model.cancelAdd() }
                    }
                }
                .padding(8)
                .background(.yellow.opacity(0.15))
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.busy { ProgressView().controlSize(.small) }
        }
        .padding(16)
        .task { await model.load() }
    }

    private var notShared: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "“\(model.node.name)” moves into a space of its own, which stays where it is in your drive. Then you choose who sees it."
            )
            .fixedSize(horizontal: false, vertical: true)
            if model.driveIsEncrypted {
                Toggle("Share it unencrypted (whoever runs your PDS can read it)", isOn: $model.plain)
            }
            Button("Share") { Task { await model.share() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("People with access").font(.headline)
            if model.people.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
            ForEach(model.people) { person in
                HStack {
                    VStack(alignment: .leading) {
                        Text(person.name)
                        if !person.notes.isEmpty {
                            Text(person.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove") { Task { await model.remove(person) } }
                }
            }
            HStack {
                TextField("alice.example.com", text: $model.newPerson)
                    .onSubmit { Task { await model.add() } }
                Button("Add") { Task { await model.add() } }
                    .disabled(model.newPerson.isEmpty || model.busy)
            }
        }
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Anyone with the link can see it",
                isOn: Binding(get: { model.linkOn }, set: { on in Task { await model.setLink(on) } }))
            if let link = model.link {
                HStack {
                    Text(link.description).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Button("Copy Link") { model.copyLink() }
                }
            }
        }
    }
}

// MARK: Opening a link

@MainActor @Observable
final class OpenLinkModel {
    let drive: JoinedDrive
    let link: ShareLinkAddress
    private(set) var opened: OpenedShare?
    private(set) var owner = ""
    private(set) var message: String?
    private(set) var done: String?
    private(set) var busy = false

    init(drive: JoinedDrive, link: ShareLinkAddress) {
        self.drive = drive
        self.link = link
    }

    func load() async {
        busy = true
        defer { busy = false }
        do {
            guard let access = drive.access else { return }
            let keys = try await drive.home.settings()?.sharingKeyPair(encrypted: drive.mode == .encrypted)
            let opened = try await JoinedDrive.open(link, access: access, sharingKeys: keys, me: drive.owner)
            self.opened = opened
            owner = await ShareModel.name(opened.owner)
        } catch {
            message = String(describing: error)
        }
    }

    func add() async {
        busy = true
        defer { busy = false }
        do {
            let mount = try await drive.add(link)
            done = "Added “\(mount.name)” to your drive. It's read-only, and kept up to date."
            await SharingCoordinator.refreshFinder()
        } catch {
            message = String(describing: error)
        }
    }

    func download() async {
        guard let opened else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true
        defer { busy = false }
        do {
            let root = try await opened.download(into: folder)
            done = "Downloaded “\(opened.name)” to \(root.path)."
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            message = String(describing: error)
        }
    }
}

struct OpenLinkView: View {
    @State var model: OpenLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let opened = model.opened {
                Text("“\(opened.name)”").font(.headline)
                Text("Shared by \(model.owner). \(opened.mode == .encrypted ? "Encrypted." : "Not encrypted.")")
                    .foregroundStyle(.secondary)
                if let done = model.done {
                    Text(done).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Button("Add to My Drive") { Task { await model.add() } }
                            .keyboardShortcut(.defaultAction)
                        Button("Download…") { Task { await model.download() } }
                    }
                    .disabled(model.busy)
                }
            } else if model.message == nil {
                ProgressView("Opening the link…")
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }
}

struct PasteLinkView: View {
    let open: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a link someone shared with you (atdrive://…).")
            TextField("atdrive://open?at=…", text: $text)
                .onSubmit { open(text) }
            Button("Open") { open(text) }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
        }
        .padding(16)
    }
}

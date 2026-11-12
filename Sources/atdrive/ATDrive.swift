import ATDriveCore
import ArgumentParser
import Foundation

@main
struct ATDrive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "atdrive",
        abstract: "A file drive stored privately in your atproto account (atproto spaces).",
        discussion: """
            Paths in the drive always start from the top: /photos/cat.jpg. Start with
            `atdrive login <handle>`.
            """,
        version: "0.1.0",
        subcommands: [
            Login.self, Logout.self, WhoAmI.self,
            List.self, Tree.self, Put.self, Get.self, Cat.self,
            MakeFolder.self, Move.self, Remove.self, Sync.self,
        ]
    )
}

/// The logged-in account and its drive, loaded once per command.
struct Context {
    let store: SessionStore
    let session: SessionManager
    let drive: Drive

    static func load() async throws -> Context {
        let store = SessionStore()
        guard let saved = try store.load() else { throw ATDriveError.notLoggedIn }
        // Token refreshes are saved as they happen, so the next command starts fresh.
        let session = SessionManager(saved) { updated in try? store.save(updated) }
        return Context(store: store, session: session, drive: try await Drive(session: session))
    }
}

/// The drive as it was when the command started, plus anything the command has created since,
/// so a command that creates `/a` and then `/a/b` sees its own work without re-listing.
struct DriveState {
    let tree: DriveTree
    private var created: [String: Node] = [:]

    init(_ tree: DriveTree) { self.tree = tree }

    func child(named name: String, in folder: String?) -> Node? {
        created[Self.key(name, folder)] ?? tree.child(named: name, in: folder)
    }

    mutating func add(_ node: Node) { created[Self.key(node.name, node.record.parent)] = node }

    private static func key(_ name: String, _ folder: String?) -> String { "\(folder ?? "")/\(name)" }
}

enum Output {
    static let isInteractive = isatty(STDERR_FILENO) != 0

    /// A line on stderr that rewrites itself (progress); a no-op when not on a terminal.
    static func status(_ line: String) {
        guard isInteractive else { return }
        FileHandle.standardError.write(Data("\r\(line)\u{1B}[K".utf8))
    }

    static func clearStatus() {
        guard isInteractive else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    static func progress(_ verb: String, _ path: DrivePath) -> Drive.Progress {
        { done, total in
            let percent = total > 0 ? done * 100 / total : 100
            status("\(verb) \(path)  \(percent)%  (\(size(done)) / \(size(total)))")
        }
    }

    static func size(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f", value) + " " + units[unit]
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

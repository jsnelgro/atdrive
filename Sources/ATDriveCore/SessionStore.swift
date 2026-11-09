import Foundation

/// Saves the session to `~/.config/atdrive/session.json` (readable only by you).
///
/// The directory can be moved with `ATDRIVE_CONFIG_DIR` or `XDG_CONFIG_HOME`. The password is
/// never stored, only the tokens the server hands back, which `atdrive logout` revokes.
public struct SessionStore: Sendable {
    public let directory: URL

    /// Stores the session in a specific folder (e.g. the macOS app's shared App Group container).
    public init(directory: URL) {
        self.directory = directory
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let dir = environment["ATDRIVE_CONFIG_DIR"], !dir.isEmpty {
            directory = URL(fileURLWithPath: dir, isDirectory: true)
        } else if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            directory = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("atdrive")
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/atdrive", isDirectory: true)
        }
    }

    public var file: URL { directory.appendingPathComponent("session.json") }

    public func load() throws -> Session? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Session.self, from: Data(contentsOf: file))
    }

    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let temporary = directory.appendingPathComponent(".session.json.tmp")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: try encoder.encode(session),
                attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
        try replace(file, with: temporary)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// Atomically moves `source` over `destination` (POSIX rename semantics).
func replace(_ destination: URL, with source: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
}

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
        try writePrivately(session, to: file)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// This device's identity, kept beside the session.
    public var devices: DeviceStore { DeviceStore(directory: directory) }
}

/// Saves this device's identity (`DeviceIdentity`) to `device.json`, beside the session and
/// readable only by you. It holds the device's private key, which the drive's keyring is wrapped
/// for: with the account's session, it opens the drive.
///
/// `atdrive logout` leaves it, so signing in again on this device doesn't need another approval.
public struct DeviceStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var file: URL { directory.appendingPathComponent("device.json") }

    public func load() throws -> DeviceIdentity? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(DeviceIdentity.self, from: Data(contentsOf: file))
    }

    public func save(_ identity: DeviceIdentity) throws {
        try writePrivately(identity, to: file)
    }

    /// This device's identity, made (with a new key pair) and saved the first time.
    public func loadOrCreate(name: String = DeviceName.current) throws -> DeviceIdentity {
        if let identity = try load() { return identity }
        let identity = DeviceIdentity(name: name)
        try save(identity)
        return identity
    }
}

/// Writes `value` as JSON to `file` atomically, readable only by its owner, in a folder only its
/// owner can open.
private func writePrivately(_ value: some Encodable, to file: URL) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let temporary = directory.appendingPathComponent(".\(file.lastPathComponent).tmp")
    guard
        FileManager.default.createFile(
            atPath: temporary.path, contents: try encoder.encode(value), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
    try replace(file, with: temporary)
}

/// Atomically moves `source` over `destination` (POSIX rename semantics).
func replace(_ destination: URL, with source: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
}

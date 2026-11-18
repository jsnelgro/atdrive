import Foundation

/// Saves the session: the OAuth tokens the server hands back, which `atdrive logout` revokes,
/// and the DPoP key they're bound to. Kept as a secret (`SecretStorage`): never in `~/.config`.
public struct SessionStore: Sendable {
    public let storage: SecretStorage

    public init(storage: SecretStorage) {
        self.storage = storage
    }

    /// Stores the session in a specific folder (e.g. the macOS app's shared App Group container).
    public init(directory: URL) {
        self.init(storage: .directory(directory))
    }

    /// Where the CLI keeps it: `SecretStorage.standard`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(storage: .standard(environment: environment))
    }

    /// The saved session; `nil` if there's none, or it's from an older version of ATDrive (an
    /// app-password session, say), which means signing in again.
    public func load() throws -> Session? {
        guard let data = try storage.read("session") else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session) throws {
        try storage.write(encode(session), as: "session")
    }

    public func delete() throws {
        try storage.delete("session")
    }

    /// This device's identity, kept beside the session.
    public var devices: DeviceStore { DeviceStore(storage: storage) }
}

/// Saves this device's identity (`DeviceIdentity`), beside the session and as secret. It holds
/// the device's private key, which the drive's keyring is wrapped for: with the account's
/// session, it opens the drive.
///
/// `atdrive logout` leaves it, so signing in again on this device doesn't need another approval.
public struct DeviceStore: Sendable {
    public let storage: SecretStorage

    public init(storage: SecretStorage) {
        self.storage = storage
    }

    public init(directory: URL) {
        self.init(storage: .directory(directory))
    }

    public func load() throws -> DeviceIdentity? {
        guard let data = try storage.read("device") else { return nil }
        return try JSONDecoder().decode(DeviceIdentity.self, from: data)
    }

    public func save(_ identity: DeviceIdentity) throws {
        try storage.write(encode(identity), as: "device")
    }

    /// Forgets this device's identity: the next one is a new device (`atdrive dev reset`).
    public func delete() throws {
        try storage.delete("device")
    }

    /// This device's identity, made (with a new key pair) and saved the first time.
    public func loadOrCreate(name: String = DeviceName.current) throws -> DeviceIdentity {
        if let identity = try load() { return identity }
        let identity = DeviceIdentity(name: name)
        try save(identity)
        return identity
    }
}

private func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

/// Atomically moves `source` over `destination` (POSIX rename semantics).
func replace(_ destination: URL, with source: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
        throw CocoaError(
            .fileWriteUnknown,
            userInfo: [
                NSFilePathErrorKey: destination.path,
                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
            ])
    }
}

import Foundation

#if canImport(Security)
    import Security
#endif

/// Where this device's secrets are kept: the account's session (OAuth tokens and the DPoP key
/// they're bound to) and the device's identity (the private key an encrypted drive's keyring is
/// wrapped for).
///
/// Never in `~/.config`: people keep that in version control with their dotfiles, and these
/// must never leave the device. Settings that aren't secret go in `config.toml` there instead
/// (`ConfigFile`).
///
/// - `ATDRIVE_STATE_DIR` names a folder to keep them in, as files only you can read.
/// - Otherwise, on a Mac, the CLI keeps them in the login Keychain.
/// - Elsewhere, in `$XDG_STATE_HOME/atdrive` (`~/.local/state/atdrive`): the XDG place for state
///   that has to last but belongs to this machine alone.
///
/// The Mac app keeps them in its App Group container (`.directory`), where its File Provider
/// extension can read them too.
public struct SecretStorage: Sendable, CustomStringConvertible {
    let backend: any SecretBackend

    /// Files in `directory` (`session.json`, `device.json`), readable only by you.
    public static func directory(_ directory: URL) -> SecretStorage {
        SecretStorage(backend: DirectoryBackend(directory: directory))
    }

    #if canImport(Security)
        /// The Keychain items that `atdrive` on a Mac keeps them in (generic passwords, one per
        /// secret, by account name).
        public static let keychainService = "me.jsnelgro.atdrive"

        /// Generic-password items in the login Keychain, under `service`.
        public static func keychain(service: String = keychainService) -> SecretStorage {
            SecretStorage(backend: KeychainBackend(service: service))
        }
    #endif

    /// Where the CLI keeps them (see the type's description).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> SecretStorage
    {
        if let directory = environment["ATDRIVE_STATE_DIR"], !directory.isEmpty {
            return .directory(URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true))
        }
        #if os(macOS)
            return .keychain()
        #else
            return .directory(defaultDirectory(environment: environment))
        #endif
    }

    /// `$XDG_STATE_HOME/atdrive`, or `~/.local/state/atdrive`.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent("atdrive", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/atdrive", isDirectory: true)
    }

    /// The folder they're kept in; `nil` when they're in the Keychain.
    public var directory: URL? { (backend as? DirectoryBackend)?.directory }

    public var description: String { backend.description }

    func read(_ name: String) throws -> Data? { try backend.read(name) }
    func write(_ data: Data, as name: String) throws { try backend.write(data, as: name) }
    func delete(_ name: String) throws { try backend.delete(name) }
}

/// One way of keeping secrets: each is some bytes under a short name (`session`, `device`).
protocol SecretBackend: Sendable, CustomStringConvertible {
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, as name: String) throws
    func delete(_ name: String) throws
}

/// `<name>.json` in a folder only its owner can open, each file readable only by its owner.
struct DirectoryBackend: SecretBackend {
    let directory: URL

    var description: String { directory.path }

    func file(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    func read(_ name: String) throws -> Data? {
        let file = file(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    /// Atomically, so a reader never sees half of it.
    func write(_ data: Data, as name: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = file(name)
        // Its own name, so two processes saving at once (the Mac app and its extension share these
        // files) don't take each other's.
        let temporary = directory.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
        do {
            try replace(file, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func delete(_ name: String) throws {
        let file = file(name)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

#if canImport(Security)
    /// Generic-password items in the login Keychain: service `service`, account `name`. Never
    /// synced to iCloud (the default for these items): a device's key belongs to that device.
    ///
    /// The first time a newly built `atdrive` reads an item, macOS asks whether to allow it
    /// ("Always Allow" stops it asking until the next build). Where nobody can answer (over SSH,
    /// say), reading fails: set `ATDRIVE_STATE_DIR` to keep them in files instead.
    struct KeychainBackend: SecretBackend {
        let service: String

        var description: String { "the login Keychain (service \(service))" }

        private func query(_ name: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: name,
            ]
        }

        func read(_ name: String) throws -> Data? {
            var query = query(name)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError(status: status, operation: "read", item: name)
            }
            return data
        }

        func write(_ data: Data, as name: String) throws {
            let update = [kSecValueData as String: data] as CFDictionary
            var status = SecItemUpdate(query(name) as CFDictionary, update)
            if status == errSecItemNotFound {
                var item = query(name)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "ATDrive (\(name))"
                status = SecItemAdd(item as CFDictionary, nil)
                // Another process added it first: save over theirs, as a file would be.
                if status == errSecDuplicateItem { status = SecItemUpdate(query(name) as CFDictionary, update) }
            }
            guard status == errSecSuccess else { throw KeychainError(status: status, operation: "save", item: name) }
        }

        func delete(_ name: String) throws {
            let status = SecItemDelete(query(name) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status, operation: "delete", item: name)
            }
        }
    }

    /// A Keychain call that failed, with macOS's own words for why.
    public struct KeychainError: Error, CustomStringConvertible, Equatable {
        public let status: OSStatus
        public let operation: String
        public let item: String

        public var description: String {
            let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            var text = "couldn't \(operation) ATDrive's \(item) in the Keychain: \(reason)"
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                text +=
                    " (where the Keychain can't ask you, e.g. over SSH, set ATDRIVE_STATE_DIR to a folder to keep it in)"
            }
            return text
        }
    }
#endif

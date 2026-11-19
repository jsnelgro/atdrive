import Foundation

#if canImport(Security)
    import Security
#endif

/// Where this device's secrets are kept: the account's session (OAuth tokens and the DPoP key
/// they're bound to) and the device's identity (the private key an encrypted drive's keyring is
/// wrapped for).
///
/// In the system's own store for secrets where there is one, and never in `~/.config`: people
/// keep that in version control with their dotfiles, and these must never leave the device.
/// Settings that aren't secret go in `config.toml` there instead (`ConfigFile`).
///
/// - **The Mac app**, its Finder extension and the `atdrive` inside it (`Contents/Helpers/atdrive`)
///   share files in their App Group container: one sign-in, and one device, for the whole Mac
///   (`appGroup`).
/// - **`atdrive` built on its own, on a Mac:** the login Keychain (`keychain`).
/// - **Linux:** the Secret Service (GNOME Keyring, KWallet, KeePassXC…) where the session bus
///   offers one, through `secret-tool`; otherwise files in `$XDG_STATE_HOME/atdrive`
///   (`~/.local/state/atdrive`), readable only by you (`linux`).
/// - `ATDRIVE_STATE_DIR` names a folder to keep them in as files instead, anywhere.
public struct SecretStorage: Sendable, CustomStringConvertible {
    let backend: any SecretBackend
    /// The Mac app's (`appGroup`).
    public let isSharedWithApp: Bool

    init(backend: any SecretBackend, isSharedWithApp: Bool = false) {
        self.backend = backend
        self.isSharedWithApp = isSharedWithApp
    }

    /// The secrets there are, by name.
    static let names = ["session", "device"]

    /// The Keychain items' service, and the Secret Service items' `service` attribute.
    public static let service = "app.atdrive"

    /// Files in `directory` (`session.json`, `device.json`), readable only by you.
    public static func directory(_ directory: URL) -> SecretStorage {
        SecretStorage(backend: DirectoryBackend(directory: directory))
    }

    /// The Mac app's, in its App Group container (`container`): its Finder extension's too, and
    /// the `atdrive` inside it. Files, for now: on macOS an App Group isn't a Keychain access
    /// group, and sharing Keychain items between the three needs provisioning profiles (#54).
    public static func appGroup(container: URL) -> SecretStorage {
        SecretStorage(
            backend: DirectoryBackend(
                directory: container.appendingPathComponent("Library/Application Support/ATDrive", isDirectory: true)),
            isSharedWithApp: true)
    }

    #if canImport(Security)
        /// Generic-password items in the login Keychain: `atdrive` built on its own, on a Mac.
        public static func keychain(service: String = service) -> SecretStorage {
            SecretStorage(backend: KeychainBackend(service: service))
        }
    #endif

    /// Linux: the Secret Service, if `secretTool` (what `SecretTool.find` found) can reach one
    /// the first time a secret is saved, and files in `directory` if not. Decided once, and
    /// remembered in `directory/storage`; delete that to decide again.
    static func linux(directory: URL, secretTool: SecretToolBackend.Runner?) -> SecretStorage {
        let files = DirectoryBackend(directory: directory)
        return SecretStorage(
            backend: LinuxBackend(
                files: files,
                secretService: secretTool.map { SecretToolBackend(lockFile: files.lockFile, run: $0) }))
    }

    /// Where the CLI keeps them (see the type's description).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> SecretStorage
    {
        if let directory = environment["ATDRIVE_STATE_DIR"], !directory.isEmpty {
            return .directory(URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true))
        }
        #if os(macOS)
            if let executable = Bundle.main.executableURL, let group = enclosingAppGroup(executable: executable),
                let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            {
                return .appGroup(container: container)
            }
            return .keychain()
        #else
            return .linux(
                directory: defaultDirectory(environment: environment),
                secretTool: SecretTool.find(environment: environment))
        #endif
    }

    /// The App Group of the ATDrive.app that `executable` is inside, at `Contents/Helpers/` (through
    /// a symlink, too: how it's put on the PATH). `build-app.sh` puts it there, signed with that
    /// group, which is what lets it into the app's container and Keychain items.
    static func enclosingAppGroup(executable: URL) -> String? {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app",
            let data = FileManager.default.contents(atPath: contents.appendingPathComponent("Info.plist").path),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let group = info["ATDriveAppGroup"] as? String, !group.isEmpty
        else { return nil }
        return group
    }

    /// `$XDG_STATE_HOME/atdrive`, or `~/.local/state/atdrive`.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent("atdrive", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/atdrive", isDirectory: true)
    }

    /// The folder of their files, or (Linux) of the files there'd be without a Secret Service;
    /// `nil` when they're in the Keychain.
    public var directory: URL? {
        switch backend {
        case let files as DirectoryBackend: files.directory
        case let linux as LinuxBackend: linux.files.directory
        default: nil
        }
    }

    /// The variables that make another process (the sync service) use this same storage.
    public var environment: [String: String] {
        switch backend {
        case let files as DirectoryBackend: ["ATDRIVE_STATE_DIR": files.directory.path]
        case let linux as LinuxBackend: ["XDG_STATE_HOME": linux.files.directory.deletingLastPathComponent().path]
        default: [:]
        }
    }

    public var description: String { backend.description + (isSharedWithApp ? " (shared with the ATDrive app)" : "") }

    /// Runs `body` holding a lock that every process using this storage respects: a `flock` on
    /// a file beside the secrets (for the Keychain, in the temporary folder). Refreshing the
    /// session holds it, since a refresh token works only once: two processes refreshing with the
    /// same one would sign one of them out.
    ///
    /// A process that dies holding it lets go (the system drops the lock with the process). One
    /// that's stuck is waited for at most `timeout`; then `body` runs anyway.
    func withLock<T>(timeout: Duration = .seconds(90), _ body: () async throws -> T) async throws -> T {
        let file = backend.lockFile
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return try await body() }  // no lock is better than no refresh
        defer { close(descriptor) }  // closing releases it
        let deadline = ContinuousClock.now + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await body()
    }

    func read(_ name: String) throws -> Data? { try backend.read(name) }
    func write(_ data: Data, as name: String) throws { try backend.write(data, as: name) }
    func delete(_ name: String) throws { try backend.delete(name) }
}

/// One way of keeping secrets: each is some bytes under a short name (`session`, `device`).
protocol SecretBackend: Sendable, CustomStringConvertible {
    /// For `SecretStorage.withLock`.
    var lockFile: URL { get }
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, as name: String) throws
    func delete(_ name: String) throws
}

/// `<name>.json` in a folder only its owner can open, each file readable only by its owner.
struct DirectoryBackend: SecretBackend {
    let directory: URL

    var description: String { directory.path }

    var lockFile: URL { directory.appendingPathComponent(".lock") }

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

/// Secrets kept in `new`, which those still in files in `old` (from an older version) move into:
/// the first time each is read, it's copied over and its file deleted, so no copy is left behind.
struct MovingBackend: SecretBackend {
    let old: DirectoryBackend
    let new: any SecretBackend

    var description: String { new.description }
    var lockFile: URL { new.lockFile }

    func read(_ name: String) throws -> Data? {
        if let data = try new.read(name) {
            try? old.delete(name)  // a leftover, if a move was cut short
            return data
        }
        guard let data = try old.read(name) else { return nil }
        try new.write(data, as: name)
        try old.delete(name)
        return data
    }

    func write(_ data: Data, as name: String) throws {
        try new.write(data, as: name)
        try? old.delete(name)
    }

    func delete(_ name: String) throws {
        try new.delete(name)
        try old.delete(name)
    }
}

/// Linux: the Secret Service where there is one, files where there isn't. Which is decided the
/// first time a secret is saved, by trying the Secret Service, and remembered in `storage` beside
/// the files: a later failure to reach it (a locked keyring, a session without a bus) is then an
/// error, never a quiet switch to files.
struct LinuxBackend: SecretBackend {
    let files: DirectoryBackend
    /// `nil` where there's no `secret-tool`, or no session bus to reach a Secret Service on.
    let secretService: SecretToolBackend?

    enum Choice: String {
        case secretService = "secret-service"
        case files
    }

    var choiceFile: URL { files.directory.appendingPathComponent("storage") }

    /// `nil`: not decided yet (nothing has been saved since there could be a Secret Service).
    var choice: Choice? {
        guard let data = FileManager.default.contents(atPath: choiceFile.path) else { return nil }
        return Choice(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var description: String {
        choice == .secretService ? secretServiceDescription : files.description
    }

    private var secretServiceDescription: String {
        "the Secret Service (your desktop's keyring), service \(SecretStorage.service)"
    }

    var lockFile: URL { files.lockFile }

    /// The Secret Service, which this machine chose.
    private func chosenService() throws -> MovingBackend {
        guard let secretService else { throw SecretServiceError.unreachable(choiceFile) }
        return MovingBackend(old: files, new: secretService)
    }

    func read(_ name: String) throws -> Data? {
        choice == .secretService ? try chosenService().read(name) : try files.read(name)
    }

    func write(_ data: Data, as name: String) throws {
        switch choice {
        case .secretService: try chosenService().write(data, as: name)
        case .files: try files.write(data, as: name)
        case nil:
            guard let secretService else { return try files.write(data, as: name) }
            // Decide: everything goes to the Secret Service if it takes it, or stays in files.
            var moved: [String] = []
            do {
                for other in SecretStorage.names where other != name {
                    guard let existing = try files.read(other) else { continue }
                    try secretService.write(existing, as: other)
                    moved.append(other)
                }
                try secretService.write(data, as: name)
                try decide(.secretService)
            } catch {
                for other in moved + [name] { try? secretService.delete(other) }
                // No Secret Service here (a server without a desktop, say): files from now on.
                try? decide(.files)
                return try files.write(data, as: name)
            }
            for other in SecretStorage.names { try? files.delete(other) }
        }
    }

    func delete(_ name: String) throws {
        choice == .secretService ? try chosenService().delete(name) : try files.delete(name)
    }

    private func decide(_ choice: Choice) throws {
        try FileManager.default.createDirectory(
            at: files.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data((choice.rawValue + "\n").utf8).write(to: choiceFile, options: .atomic)
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

        /// The temporary folder is this user's own on a Mac.
        var lockFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("\(service).lock") }

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

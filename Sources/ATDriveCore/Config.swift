import Foundation

/// This machine's settings: the ones that aren't secret and aren't the drive's.
///
/// - The drive's own settings (encryption, how long history is kept) are in its settings record,
///   so every device follows them (`DriveSettings`).
/// - Secrets (the session, this device's key) are never in a config file (`SecretStorage`).
/// - Everything else is here, in `config.toml` (`ConfigFile`), which the CLI and the Mac app both
///   read, and the Mac app's Settings window writes. It's safe to keep in a dotfiles repository.
public struct LocalConfig: Sendable, Equatable {
    /// Seconds between checks for changes made elsewhere: `atdrive sync`'s, and the Mac app's.
    public var syncInterval = 30

    public static let minimumSyncInterval = 5

    /// Show what's in every space you're in (other apps' data, and spaces shared with you),
    /// read-only: in `atdrive spaces`, and on a Mac as a second Finder location (Spaces). Off by
    /// default: it downloads other people's data, and (once ATDrive's scope is narrow) needs a
    /// wider sign-in (`OAuthLogin.spacesScope`).
    public var spacesEnabled = false

    /// Let Spotlight search the Spaces location in Finder. Off by default, so other people's data
    /// shared with you doesn't turn up in searches.
    public var spacesSpotlight = false

    public init() {}

    /// Every setting: its key in the file, what it does, and how it's read and written. Adding a
    /// setting is adding one here.
    static let settings: [Setting] = [
        Setting(
            key: "sync.interval",
            help: "Seconds between checks for changes made elsewhere (atdrive sync, and the Mac app). At least 5.",
            read: { config, value in
                guard case .integer(let seconds) = value else { return "must be a whole number of seconds" }
                guard seconds >= LocalConfig.minimumSyncInterval else {
                    return "must be at least \(LocalConfig.minimumSyncInterval) seconds"
                }
                config.syncInterval = seconds
                return nil
            },
            value: { .integer($0.syncInterval) }),
        Setting(
            key: "spaces.enabled",
            help:
                "Show what's in every space you're in (other apps' data, spaces shared with you), read-only (atdrive spaces; Spaces in Finder).",
            read: { config, value in
                guard case .boolean(let enabled) = value else { return "must be true or false" }
                config.spacesEnabled = enabled
                return nil
            },
            value: { .boolean($0.spacesEnabled) }),
        Setting(
            key: "spaces.spotlight",
            help: "Let Spotlight search Spaces in Finder (other people's data included).",
            read: { config, value in
                guard case .boolean(let indexed) = value else { return "must be true or false" }
                config.spacesSpotlight = indexed
                return nil
            },
            value: { .boolean($0.spacesSpotlight) }),
    ]

    struct Setting: Sendable {
        let key: String
        let help: String
        /// Takes the value from the file; what's wrong with it, if it can't.
        let read: @Sendable (inout LocalConfig, TOMLDocument.Value) -> String?
        let value: @Sendable (LocalConfig) -> TOMLDocument.Value
    }
}

/// `config.toml`: `LocalConfig` as a file.
///
/// The CLI's is `$ATDRIVE_CONFIG_DIR/config.toml`, or `$XDG_CONFIG_HOME/atdrive/config.toml`
/// (`~/.config/atdrive/config.toml`). The Mac app, which can't see your shell's variables, always
/// uses `~/.config/atdrive/config.toml`.
public struct ConfigFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The CLI's.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ConfigFile {
        let directory: URL
        if let configured = environment["ATDRIVE_CONFIG_DIR"], !configured.isEmpty {
            directory = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        } else if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            directory = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("atdrive")
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/atdrive", isDirectory: true)
        }
        return ConfigFile(url: directory.appendingPathComponent("config.toml"))
    }

    /// `~/.config/atdrive/config.toml` in `home`: the Mac app's (sandboxed, it passes the real
    /// home folder, not its container).
    public static func inHome(_ home: URL) -> ConfigFile {
        ConfigFile(url: home.appendingPathComponent(".config/atdrive/config.toml"))
    }

    /// The settings, and how each came to be.
    public struct Loaded: Sendable, Equatable {
        public var config: LocalConfig
        /// Every setting, in order, with its value as TOML.
        public var entries: [Entry]
        /// Keys the file sets that ATDrive doesn't know (misspelled, or from a newer version).
        public var unknownKeys: [String]
        public var exists: Bool
    }

    public struct Entry: Sendable, Equatable {
        public var key: String
        public var value: String
        public var help: String
        /// In the file, rather than the default.
        public var isSet: Bool
    }

    /// The settings: the defaults where the file doesn't say, or there's no file. Throws
    /// `ConfigError` for a file that can't be read as TOML, or a value that's wrong.
    public func load() throws -> LocalConfig { try loadInDetail().config }

    public func loadInDetail() throws -> Loaded {
        let (document, exists) = try read()
        var config = LocalConfig()
        var entries: [Entry] = []
        for setting in LocalConfig.settings {
            if let entry = document.entries[setting.key] {
                if let problem = setting.read(&config, entry.value) {
                    throw ConfigError(file: url, line: entry.line + 1, message: "\(setting.key) \(problem)")
                }
            }
            entries.append(
                Entry(
                    key: setting.key, value: setting.value(config).description, help: setting.help,
                    isSet: document.entries[setting.key] != nil))
        }
        let known = Set(LocalConfig.settings.map(\.key))
        let unknown = document.entries.keys.filter { !known.contains($0) }.sorted()
        return Loaded(config: config, entries: entries, unknownKeys: unknown, exists: exists)
    }

    /// Changes settings, writing only the ones that changed, each in place: the rest of the file
    /// (comments included) stays as it is. Creates the file if there's none. Refuses a file it
    /// can't read rather than replace it.
    public func update(_ change: (inout LocalConfig) -> Void) throws {
        let (document, exists) = try read()
        let before = try loadInDetail().config
        var after = before
        change(&after)
        let changed = LocalConfig.settings.filter { $0.value(after) != $0.value(before) }
        guard !changed.isEmpty else { return }
        var edited = exists ? document : try! TOMLDocument(parsing: Self.header)
        for setting in changed {
            var check = LocalConfig()
            if let problem = setting.read(&check, setting.value(after)) {
                throw ConfigError(file: url, line: nil, message: "\(setting.key) \(problem)")
            }
            edited.set(setting.key, to: setting.value(after))
        }
        try write(edited.text)
    }

    /// What a new file starts with.
    static let header = """
        # ATDrive's settings for this computer. Nothing secret is kept here, so this file is safe to
        # keep with your dotfiles. Your session and this device's key are kept elsewhere: run
        # `atdrive config` to see where, and every setting there is.

        """

    private func read() throws -> (TOMLDocument, exists: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (try! TOMLDocument(parsing: ""), false)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            return (try TOMLDocument(parsing: text), true)
        } catch {
            throw ConfigError(file: url, line: error.line, message: error.message)
        }
    }

    /// Atomically, so a reader (the other app) never sees half of it.
    private func write(_ text: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temporary)
        do {
            try replace(url, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// `config.toml` can't be used as it is.
public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let file: URL
    public let line: Int?
    public let message: String

    public var description: String {
        "\(file.path)\(line.map { ", line \($0)" } ?? ""): \(message)"
    }
}

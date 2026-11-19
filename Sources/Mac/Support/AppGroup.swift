import ATDriveCore
import FileProvider
import Foundation

/// Things the menu-bar app and the File Provider extension must agree on.
///
/// They're separate sandboxed processes, so they share data through an App Group container.
/// The group ID includes your Team ID, which the build script writes into each bundle's
/// Info.plist (`ATDriveAppGroup`) rather than it being hardcoded here.
public enum AppGroup {
    public static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "ATDriveAppGroup") as? String
    }

    public static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// Where the logged-in session lives, shared by the app, the extension and the `atdrive` inside
    /// the app (`SecretStorage.appGroup`).
    public static func sessionStore() -> SessionStore? {
        containerURL.map { SessionStore(storage: .appGroup(container: $0)) }
    }

    /// Where this Mac's device identity lives (its key pair, which the drive's keyring is wrapped
    /// for), beside the session. The app makes it; the extension uses it to unlock the drive.
    public static func deviceStore() -> DeviceStore? {
        sessionStore()?.devices
    }
}

/// This Mac's settings: `~/.config/atdrive/config.toml`, the same file the `atdrive` CLI uses,
/// so there's one place to change them.
public enum UserConfig {
    public static var file: ConfigFile { ConfigFile.inHome(home) }

    /// The real home folder. Sandboxed, `FileManager`'s is the app's container; the app's
    /// entitlements let it into `~/.config/atdrive` there and nowhere else.
    static var home: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// The Finder location ATDrive shows up as. One domain, for the logged-in account.
public enum DriveDomain {
    public static let identifier = NSFileProviderDomainIdentifier(rawValue: "default")

    public static func make(displayName: String) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        // We don't keep a trash on the server; deleting in Finder deletes from the drive.
        domain.supportsSyncingTrash = false
        return domain
    }

    /// The manager for the drive's domain (looked up by identifier; the name doesn't matter).
    public static var manager: NSFileProviderManager? {
        NSFileProviderManager(for: make(displayName: "ATDrive"))
    }
}

/// The second Finder location: what's in every space the account is in (other apps' data, and
/// spaces shared with it), read-only (`SpaceData`). There only while `spaces.enabled` is on in
/// config.toml: the app adds and removes it.
public enum SpacesDomain {
    public static let identifier = NSFileProviderDomainIdentifier(rawValue: "spaces")

    /// Finder shows it as "Spaces" under ATDrive in the sidebar.
    public static func make() -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Spaces")
        domain.supportsSyncingTrash = false
        return domain
    }

    public static var manager: NSFileProviderManager? { NSFileProviderManager(for: make()) }

    /// Whether Spotlight may index it (`spaces.spotlight` in config.toml). The extension can't read
    /// config.toml, so the app passes it on through the App Group's defaults.
    public static var spotlight: Bool {
        get { defaults?.bool(forKey: spotlightKey) ?? false }
        set { defaults?.set(newValue, forKey: spotlightKey) }
    }

    private static let spotlightKey = "spacesSpotlight"
    private static var defaults: UserDefaults? { AppGroup.identifier.flatMap { UserDefaults(suiteName: $0) } }
}

public enum Log {
    public static let subsystem = "me.jsnelgro.atdrive"
}

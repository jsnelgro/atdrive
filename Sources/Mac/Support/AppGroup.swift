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

    /// Where the logged-in session lives, readable by both the app and the extension.
    public static func sessionStore() -> SessionStore? {
        containerURL.map {
            SessionStore(directory: $0.appendingPathComponent("Library/Application Support/ATDrive", isDirectory: true))
        }
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

public enum Log {
    public static let subsystem = "me.jsnelgro.atdrive"
}

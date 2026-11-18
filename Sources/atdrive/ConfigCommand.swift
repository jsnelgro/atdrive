import ATDriveCore
import ArgumentParser
import Foundation

struct ShowConfig: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show this computer's settings, and where they and your secrets are kept.",
        discussion: """
            Settings are in config.toml, which is safe to keep with your dotfiles: nothing secret goes in it. Edit it to change them; the Mac app's Settings window changes the same file. The drive's own settings (encryption, how long history is kept) are kept in the drive, for every device.

            Your session and this device's key are kept elsewhere: in the login Keychain on a Mac, and in $XDG_STATE_HOME/atdrive (~/.local/state/atdrive) on Linux. ATDRIVE_STATE_DIR moves them to a folder of your choice, and ATDRIVE_CONFIG_DIR moves config.toml.
            """
    )

    func run() async throws {
        let file = ConfigFile.standard()
        let loaded = try file.loadInDetail()
        print("Settings: \(file.url.path)\(loaded.exists ? "" : " (not created yet: everything is at its default)")")
        let width = loaded.entries.map { $0.key.count + $0.value.count }.max() ?? 0
        for entry in loaded.entries {
            let assignment = "\(entry.key) = \(entry.value)"
            let padding = String(repeating: " ", count: width - entry.key.count - entry.value.count)
            print("  \(assignment)\(padding)  \(entry.isSet ? "" : "(default) ")# \(entry.help)")
        }
        for key in loaded.unknownKeys { Output.warn("config.toml sets \(key), which isn't a setting") }
        print("Secrets (your session and this device's key): \(SessionStore().storage)")
    }
}

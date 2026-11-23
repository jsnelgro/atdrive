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
        print("# \(file.url.path)\(loaded.exists ? "" : " (not created yet)")")
        print("# Settings that are commented out are at their defaults: uncomment one to change it.")
        print("")
        print(loaded.toml)
        for key in loaded.unknownKeys { Output.warn("config.toml sets \(key), which isn't a setting") }
        print("# Your session and this device's key are kept elsewhere: \(SessionStore().storage)")
    }
}

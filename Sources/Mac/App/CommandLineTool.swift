import AppKit

/// The `atdrive` command inside the app (`Contents/Helpers/atdrive`, put there by build-app.sh).
/// It shares the app's sign-in and this Mac's key, so it needs no sign-in of its own and the drive
/// sees one device. The app is sandboxed and can't put it on the PATH itself, so it shows the
/// command that does, and copies it.
@MainActor
enum CommandLineTool {
    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/atdrive") }

    static let link = "/usr/local/bin/atdrive"

    /// A link from the PATH to the command inside the app, so it follows the app when it's
    /// rebuilt in place.
    static var installCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \(quote(executable.path)) \(link)"
    }

    static func showInstructions() {
        NSApp.activate()
        let alert = NSAlert()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            alert.messageText = "This copy of ATDrive has no atdrive command"
            alert.informativeText = "Build it again with scripts/build-app.sh, which puts the command inside the app."
            alert.runModal()
            return
        }
        alert.messageText = "Install the atdrive command"
        alert.informativeText = """
            The atdrive command inside ATDrive uses this Mac's sign-in and keys: there's nothing to sign in to again, and signing out of one signs out of both.

            To use it in Terminal, run this (it asks for your password, to write to /usr/local/bin):

            \(installCommand)
            """
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        }
    }

    /// For the shell: in single quotes, each `'` closed, escaped and reopened.
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

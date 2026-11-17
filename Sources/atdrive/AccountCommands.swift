import ATDriveCore
import ArgumentParser
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in through your account's sign-in page in the browser.",
        discussion: """
            Opens your PDS's own sign-in page; ATDrive never sees your password. After you
            approve access, the browser hands control back to this command.

            Signing in on a remote machine (over SSH, or without a desktop): open the printed
            link in a browser on any device, approve, then paste the address the browser ends
            up on (it starts with http://127.0.0.1 and won't load) back here.

            With no drive yet, one is created. It isn't encrypted unless you pass --encrypted
            (or turn encryption on later with `atdrive encryption on`): whoever runs your PDS
            can read an unencrypted drive, and there are no keys to lose. An encrypted drive's
            recovery key is shown once. For an encrypted drive made elsewhere, approve this
            device from one that has the keys (`atdrive devices approve`, comparing a code shown
            on both), or type the recovery key.
            """
    )

    @Argument(help: "Your handle (e.g. alice.example.com) or DID.")
    var handle: String

    @Flag(help: "If this creates the drive: encrypt it, so whoever runs your PDS can't read it.")
    var encrypted = false

    func run() async throws {
        let local = hasLocalBrowser
        let interactive = isatty(STDIN_FILENO) != 0
        let session = try await OAuthLogin.signIn(
            identifier: handle,
            open: { url in
                if local {
                    write(
                        "Opening your browser to sign in. If it doesn't open, go to:\n\n  \(url.absoluteString)\n\n"
                    )
                    openInBrowser(url)
                } else {
                    write(
                        """
                        Open this link in a browser on any device to sign in:

                          \(url.absoluteString)

                        After you approve, the browser goes to a page that won't load (its address
                        starts with http://127.0.0.1). Copy that address and paste it here:

                        """)
                }
            },
            // Also accepted on a desktop, in case the browser turns out to be elsewhere.
            pastedRedirect: interactive ? readPastedAddress : nil)
        try SessionStore().save(session)
        print("Logged in as @\(session.handle) (\(session.did)) on \(session.service.host ?? "\(session.service)")")
        try await KeySetup.run(encrypted: encrypted)
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Log out and revoke the saved session.")

    func run() async throws {
        let store = SessionStore()
        guard let session = try store.load() else {
            print("Not logged in.")
            return
        }
        await Auth.logout(session)
        try store.delete()
        print("Logged out @\(session.handle).")
    }
}

struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whoami", abstract: "Show the logged-in account and where its drive lives.")

    func run() async throws {
        let context = try await Context.locked()
        let session = await context.session.session
        print("handle: @\(session.handle)")
        print("did:    \(session.did)")
        print("pds:    \(session.service.absoluteString)")
        print("drive:  \(context.drive.space)")
        do {
            switch try await context.drive.open() {
            case .plain:
                print("        not encrypted (`atdrive encryption on` turns encryption on)")
            case .encrypted:
                print("        encrypted")
                if let device = context.drive.identity { print("device: \(device.name) (\(device.id))") }
                print("keys:   this device has the drive's keys")
            }
        } catch let error as DriveAccessError {
            if context.drive.mode == .encrypted { print("        encrypted") }
            print("keys:   \(error)")
        }
    }
}

/// Opens a URL in the default browser (best effort: the URL is printed too).
private func openInBrowser(_ url: URL) {
    let process = Process()
    #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
    #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url.absoluteString]
    #endif
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// Whether a browser opened here can reach this machine's 127.0.0.1: not over SSH, and on
/// Linux only with a desktop session.
private var hasLocalBrowser: Bool {
    let environment = ProcessInfo.processInfo.environment
    if environment["SSH_CONNECTION"] != nil || environment["SSH_TTY"] != nil { return false }
    #if os(macOS)
        return true
    #else
        return environment["DISPLAY"] != nil || environment["WAYLAND_DISPLAY"] != nil
    #endif
}

/// Reads lines until one is the sign-in address from the browser.
@Sendable private func readPastedAddress() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            while let line = readLine() {
                if (try? OAuthLogin.redirectParameters(fromPasted: line)) != nil {
                    return continuation.resume(returning: line)
                }
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    write("That's not it: paste the whole address, starting with http://127.0.0.1\n")
                }
            }
            continuation.resume(throwing: CancellationError())  // stdin closed
        }
    }
}

/// Unbuffered, so it shows up right away even when output isn't a terminal.
private func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

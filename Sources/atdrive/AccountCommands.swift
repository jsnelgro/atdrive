import ATDriveCore
import ArgumentParser
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in through your account's sign-in page in the browser.",
        discussion: """
            Opens your PDS's own sign-in page; ATDrive never sees your password. Then your
            passkey unlocks your drive, which is encrypted so your PDS can't read it. The first
            time, you make the passkey; it syncs to your other devices like any other.

            Signing in on a remote machine (over SSH, or without a desktop): open each printed
            link in a browser on any device, then paste the address the browser ends up on (it
            starts with http://127.0.0.1 and won't load) back here.

            For scripts, --app-password signs in with an app password instead (the drive is
            still unlocked with your passkey).
            """
    )

    @Argument(help: "Your handle (e.g. alice.example.com) or DID.")
    var handle: String

    @Flag(help: "Log in with an app password instead of the browser (for servers and scripts).")
    var appPassword = false

    @Flag(help: "With --app-password: read the password from standard input.")
    var passwordStdin = false

    func run() async throws {
        // Also accepted on a desktop, in case the browser turns out to be elsewhere.
        let paste = isatty(STDIN_FILENO) != 0 ? readPastedAddress : nil
        let session: Session
        if appPassword || passwordStdin || ProcessInfo.processInfo.environment["ATDRIVE_APP_PASSWORD"] != nil {
            let signedIn = try await Auth.login(
                identifier: handle, password: try readPassword(), resolver: IdentityResolver())
            session = try await SignIn.unlock(signedIn, open: Self.show, paste: paste)
        } else {
            session = try await SignIn.run(identifier: handle, open: Self.show, paste: paste)
        }
        let store = SessionStore()
        try store.save(session)
        print("Logged in as @\(session.handle) (\(session.did)) on \(session.service.host ?? "\(session.service)")")

        // Drives from before encryption: encrypt what's there now.
        let manager = SessionManager(session) { updated in try? store.save(updated) }
        let encrypted = try await Drive(session: manager).encryptOlderItems { done, total in
            Output.status("Encrypting your drive: \(done) of \(total) items")
        }
        Output.clearStatus()
        if encrypted > 0 { print("Encrypted \(encrypted) item(s) saved before ATDrive encrypted drives.") }
    }

    @Sendable private static func show(_ url: URL, _ step: SignIn.Step) async throws {
        let local = hasLocalBrowser
        switch step {
        case .signIn where local:
            write("Opening your browser to sign in. If it doesn't open, go to:\n\n  \(url.absoluteString)\n\n")
            openInBrowser(url)
        case .signIn:
            write(
                """
                Open this link in a browser on any device to sign in:

                  \(url.absoluteString)

                After you approve, the browser goes to a page that won't load (its address
                starts with http://127.0.0.1). Copy that address and paste it here:

                """)
        case .unlock(alreadyOpen: true):
            write("Signed in. Now unlock your drive with your passkey, in the browser.\n")
        case .unlock(alreadyOpen: false) where local:
            write(
                "Opening your browser to unlock your drive with your passkey. If it doesn't open, go to:\n\n  \(url.absoluteString)\n\n"
            )
            openInBrowser(url)
        case .unlock(alreadyOpen: false):
            write(
                """

                Now open this link in a browser to unlock your drive with your passkey:

                  \(url.absoluteString)

                Then, as before, paste the address the browser ends up on here:

                """)
        }
    }

    private func readPassword() throws -> String {
        if let password = ProcessInfo.processInfo.environment["ATDRIVE_APP_PASSWORD"], !password.isEmpty {
            return password
        }
        if passwordStdin {
            guard let line = readLine(strippingNewline: true), !line.isEmpty else {
                throw ValidationError("no password on standard input")
            }
            return line
        }
        guard isatty(STDIN_FILENO) != 0, let typed = getpass("App password: ") else {
            throw ValidationError("no terminal to ask for a password; use --password-stdin")
        }
        let password = String(cString: typed)
        guard !password.isEmpty else { throw ValidationError("empty password") }
        return password
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
        guard let session = try SessionStore().load() else { throw ATDriveError.notLoggedIn }
        print("handle: @\(session.handle)")
        print("did:    \(session.did)")
        print("pds:    \(session.service.absoluteString)")
        print(
            "drive:  \(XRPCClient.spaceURI(authority: session.did, type: Lexicon.driveSpace, key: Lexicon.defaultDriveKey))"
        )
        print("locked: \(session.driveKey == nil ? "yes (sign in again to unlock it)" : "no")")
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

/// Reads lines until one is the address from the browser, for a step of signing in.
@Sendable private func readPastedAddress(for step: SignIn.Step) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            while let line = readLine() {
                let valid =
                    step == .signIn
                    ? (try? OAuthLogin.redirectParameters(fromPasted: line)) != nil
                    : PasskeyRequest.answer(fromPasted: line) != nil
                if valid {
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

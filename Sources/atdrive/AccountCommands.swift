import ATDriveCore
import ArgumentParser
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in through your account's sign-in page in the browser.",
        discussion: """
            Opens your PDS's own sign-in page; ATDrive never sees your password. After you
            approve access, the browser hands control back to this command.

            On a machine without a browser, use --app-password with an app password from your
            account settings (or set ATDRIVE_APP_PASSWORD).
            """
    )

    @Argument(help: "Your handle (e.g. alice.example.com) or DID.")
    var handle: String

    @Flag(help: "Log in with an app password instead of the browser (for servers and scripts).")
    var appPassword = false

    @Flag(help: "With --app-password: read the password from standard input.")
    var passwordStdin = false

    func run() async throws {
        let session: Session
        if appPassword || passwordStdin || ProcessInfo.processInfo.environment["ATDRIVE_APP_PASSWORD"] != nil {
            session = try await Auth.login(
                identifier: handle, password: try readPassword(), resolver: IdentityResolver())
        } else {
            session = try await OAuthLogin.signIn(identifier: handle) { url in
                // Written unbuffered, so it shows up even when output isn't a terminal.
                FileHandle.standardOutput.write(
                    Data(
                        "Opening your browser to sign in. If it doesn't open, go to:\n\n  \(url.absoluteString)\n\n"
                            .utf8))
                openInBrowser(url)
            }
        }
        try SessionStore().save(session)
        print("Logged in as @\(session.handle) (\(session.did)) on \(session.service.host ?? "\(session.service)")")
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
        let context = try await Context.load()
        let session = await context.session.session
        print("handle: @\(session.handle)")
        print("did:    \(session.did)")
        print("pds:    \(session.service.absoluteString)")
        print("drive:  \(context.drive.space)")
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

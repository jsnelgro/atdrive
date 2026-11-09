import ATDriveCore
import ArgumentParser
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log in with your handle and an app password.",
        discussion: """
            The password is used once to start a session and is never saved. Use an app
            password rather than your main one. Set ATDRIVE_APP_PASSWORD or pass
            --password-stdin to log in without a prompt.
            """
    )

    @Argument(help: "Your handle (e.g. alice.example.com) or DID.")
    var handle: String

    @Flag(help: "Read the password from standard input.")
    var passwordStdin = false

    func run() async throws {
        let password = try readPassword()
        let session = try await Auth.login(
            identifier: handle, password: password, resolver: IdentityResolver())
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

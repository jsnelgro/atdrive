import ATDriveCore
import ArgumentParser
import Foundation

struct AppPasswords: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-passwords",
        abstract: "List, create and delete your account's app passwords.",
        discussion: """
            App passwords let scripts and other tools sign in as you (for example
            `atdrive login --app-password`). Managing them needs your account password,
            because your PDS doesn't allow it with a browser sign-in. The password is used
            for this one command and isn't saved.
            """,
        subcommands: [ListAppPasswords.self, CreateAppPassword.self, DeleteAppPassword.self],
        defaultSubcommand: ListAppPasswords.self
    )
}

struct AccountPasswordOptions: ParsableArguments {
    @Flag(help: "Read your account password from standard input.")
    var passwordStdin = false

    /// Unlocks app-password management for the logged-in account, runs `body`, and always ends
    /// the temporary session afterwards.
    func withManager<T>(_ body: (AppPasswordManager) async throws -> T) async throws -> T {
        guard let account = try SessionStore().load() else { throw ATDriveError.notLoggedIn }
        let password = try readSecret(
            prompt: "Account password for @\(account.handle): ", fromStandardInput: passwordStdin)
        let manager = try await AppPasswordManager.unlock(account: account, password: password)
        do {
            let result = try await body(manager)
            await manager.lock()
            return result
        } catch {
            await manager.lock()
            throw error
        }
    }
}

struct ListAppPasswords: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List app passwords.")

    @OptionGroup var account: AccountPasswordOptions

    func run() async throws {
        let passwords = try await account.withManager { try await $0.list() }
        if passwords.isEmpty { return print("No app passwords.") }
        let width = max(passwords.map(\.name.count).max() ?? 0, 4)
        for password in passwords {
            let created = Output.date(password.createdDate)
            let note = password.privileged == true ? "  (privileged)" : ""
            print("\(password.name.padding(toLength: width, withPad: " ", startingAt: 0))  created \(created)\(note)")
        }
    }
}

struct CreateAppPassword: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Create an app password and print it (shown only once).")

    @Argument(help: "A name to recognize it by, e.g. laptop-cli.")
    var name: String

    @OptionGroup var account: AccountPasswordOptions

    func validate() throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("the name can't be empty") }
    }

    func run() async throws {
        let created = try await account.withManager { try await $0.create(name: name) }
        guard isatty(STDOUT_FILENO) != 0 else { return print(created.password) }  // piped: just the password
        print(
            "Created app password \"\(created.name)\":\n\n  \(created.password)\n\nCopy it now: it won't be shown again."
        )
    }
}

struct DeleteAppPassword: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an app password. Anything signed in with it is signed out within about 2 hours.",
        discussion: """
            Deleting it stops anything signed in with it from renewing its session. An access token
            it already holds keeps working until it expires (2 hours on Bluesky's PDS); the
            server offers no way to cut that short.
            """)

    @Argument(help: "Its name, as shown by `atdrive app-passwords`.")
    var name: String

    @OptionGroup var account: AccountPasswordOptions

    func run() async throws {
        try await account.withManager { manager in
            guard try await manager.list().contains(where: { $0.name == name }) else {
                throw ValidationError("no app password named \"\(name)\"")
            }
            try await manager.revoke(name: name)
        }
        print("Deleted app password \"\(name)\". Anything signed in with it is signed out within about 2 hours.")
    }
}

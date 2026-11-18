import ATDriveCore
import ArgumentParser
import Foundation

/// For developing and testing ATDrive, not for everyday use.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "For developing and testing ATDrive.",
        subcommands: [Reset.self, DiskUsage.self, Lexicons.self])
}

struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete everything, as if ATDrive had never been used on your account.",
        discussion: """
            For trying things out and testing: takes your account back to a clean slate. It deletes:
            - your drive, with everything in it and all its history;
            - everything you shared (people you shared it with lose it too);
            - your published sharing key, and this device's identity.
            Things other people shared with you aren't touched; they're no longer in your drive.

            Afterwards your account has no drive. The next sign-in (`atdrive login`, or the Mac
            app) makes one, and asks whether to encrypt it. Your other devices have to sign in
            again, and a synced folder of the old drive stops syncing (its files stay where they
            are).
            """)

    @Flag(name: .shortAndLong, help: "Don't ask: delete straight away.")
    var yes = false

    func run() async throws {
        let context = try await Context.locked()
        let session = await context.session.session
        if !yes {
            print(
                "This deletes everything in @\(session.handle)'s drive, and every folder it shared. It can't be undone."
            )
            guard Prompt.isInteractive else {
                throw ValidationError("not on a terminal to confirm: pass --yes")
            }
            let typed = Prompt.line("Type your handle (\(session.handle)) to confirm: ")?
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard typed?.lowercased() == session.handle.lowercased() else {
                print("Nothing deleted.")
                return
            }
        }
        let result = try await AccountReset.run(client: context.drive.client, owner: session.did)
        try context.store.devices.delete()
        let shared = result.spaces.filter { $0 != context.drive.space }.count
        print("✓ Deleted your drive\(shared > 0 ? " and \(shared) share\(shared == 1 ? "" : "s")" : "").")
        print("Your account has no drive now. Signing in (`atdrive login`, or the Mac app) makes one.")
    }
}

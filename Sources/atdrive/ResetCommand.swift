import ATDriveCore
import ArgumentParser
import Foundation

struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete your whole drive and start again with an empty one.",
        discussion: """
            For trying things out and testing: takes your account back to a clean slate, as if
            ATDrive had never been used on it. It deletes:
            - your drive, with everything in it and all its history;
            - every folder you shared (people you shared them with lose them too);
            - your published sharing key, and this device's identity.
            Folders other people shared with you aren't touched; they're no longer in your drive.

            Then it makes a new, empty drive (encrypted with --encrypted). Your other devices
            have to sign in again, and a synced folder of the old drive stops syncing (its
            files stay where they are).
            """)

    @Flag(help: "Don't ask: delete straight away.")
    var yes = false

    @Flag(help: "Make the new drive encrypted.")
    var encrypted = false

    func run() async throws {
        let context = try await Context.locked()
        let session = await context.session.session
        if !yes {
            print("This deletes everything in @\(session.handle)'s drive, and every folder it shared. It can't be undone.")
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
        let devices = context.store.devices
        if FileManager.default.fileExists(atPath: devices.file.path) {
            try FileManager.default.removeItem(at: devices.file)
        }
        let shared = result.spaces.filter { $0 != context.drive.space }.count
        print("✓ Deleted your drive\(shared > 0 ? " and \(shared) shared folder\(shared == 1 ? "" : "s")" : "").")
        try await KeySetup.run(encrypted: encrypted)
    }
}

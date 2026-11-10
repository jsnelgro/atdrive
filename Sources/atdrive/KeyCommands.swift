import ATDriveCore
import ArgumentParser
import Foundation

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The devices that hold the drive's keys, and those asking for them.",
        discussion: """
            The drive is encrypted: only devices that hold its keys can read it. A new device asks for them when you run `atdrive login` there; approve it from one that has them, after checking both show the same code. Or set it up with the recovery key (`atdrive unlock`).
            """,
        subcommands: [ListDevices.self, ApproveDevice.self, RemoveDevice.self],
        defaultSubcommand: ListDevices.self
    )
}

struct ListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the drive's devices.")

    func run() async throws {
        let context = try await Context.locked()
        // Unlocked, the roster says which are approved; without the keys, only their records do.
        let unlocked = (try? await context.drive.unlock()) != nil
        let devices = try await context.drive.devices()
        let width = devices.map(\.name.count).max() ?? 0
        for device in devices {
            let status = device.approved ? "approved" : "waiting for approval"
            let marker = device.isThisDevice ? "*" : " "
            let note = device.isThisDevice ? "  (this device)" : ""
            print("\(marker) \(device.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(device.id)  \(status)\(note)")
        }
        if !unlocked {
            print("\n(This device doesn't have the drive's keys, so these are as the records say.)")
        }
        if devices.contains(where: { !$0.approved }) {
            print("\nTo approve one: atdrive devices approve <name>")
        }
    }
}

struct ApproveDevice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve", abstract: "Give a waiting device the drive's keys.",
        discussion: """
            Shows a 16-digit code. The new device shows the same one, unless something in between swapped in a key of its own: approve only if they match.
            """)

    @Argument(help: "The device's name or ID (default: the only one waiting).")
    var device: String?

    func run() async throws {
        let context = try await Context.load()
        let drive = context.drive
        guard let me = drive.identity else { throw DriveAccessError.locked }
        let waiting = try await drive.devices().filter { !$0.approved && !$0.isThisDevice }
        let target: DeviceInfo
        if let device {
            target = try pick(device, from: waiting, describing: "waiting for approval")
        } else {
            switch waiting.count {
            case 0:
                print("No device is waiting. On the new device, run `atdrive login`.")
                return
            case 1: target = waiting[0]
            default:
                print("Several devices are waiting:")
                for device in waiting { print("  \(device.name)  \(device.id)") }
                throw ValidationError("say which: atdrive devices approve <name or ID>")
            }
        }
        let code = try target.pairingCode(with: me)
        print(
            """
            “\(target.name)” (\(target.id)) is asking for the drive's keys.

              Code: \(code)

            “\(target.name)” shows a code too. If it isn't the same, something swapped in a key
            of its own: don't approve.
            """)
        guard Prompt.confirm("Does “\(target.name)” show the same code?") else {
            print("Not approved.")
            return
        }
        try await drive.approve(target)
        print("✓ Approved “\(target.name)”. It now has the drive's keys, once it confirms this device's code too.")
    }
}

struct RemoveDevice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Take a device's access to the drive away.",
        discussion: """
            The drive gets a new key for everything written from now on, which the removed device never gets. It keeps what it could already read: everything written before, and its own copies. Until you revoke its session in your account's settings, it can also still sign in and write to the drive.
            """)

    @Argument(help: "The device's name or ID.")
    var device: String

    func run() async throws {
        let context = try await Context.load()
        let drive = context.drive
        let devices = try await drive.devices()
        let target = try pick(device, from: devices.filter { !$0.isThisDevice }, describing: "in this drive")
        guard target.approved else {
            guard Prompt.confirm("“\(target.name)” is only waiting for approval. Remove its request?") else { return }
            try await drive.remove(target.id, recoveryKey: nil)
            print("✓ Removed “\(target.name)”'s request.")
            return
        }
        print(
            """
            Removing “\(target.name)” (\(target.id)):
              - It's taken off the drive's devices, and the drive gets a new key for everything
                written from now on. “\(target.name)” never gets it.
              - It keeps what it could already read: everything written before now, and any
                copies it has. Removing it can't take those back.
              - It can still sign in to your account, and so write to the drive, until you revoke
                its session in your account's settings (or delete its app password). Until every
                other device has seen the removal, what it writes there may still be read.
            """)
        guard Prompt.confirm("Remove “\(target.name)”?") else { return }

        // The recovery key must open the new key too, and only the recovery key itself can wrap it.
        print("\nThe recovery key has to open the drive's new key too.")
        let typed = Prompt.secret("Type your recovery key, or press Enter to make a new one instead: ")
        let recoveryKey: RecoveryKey
        if let typed, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            recoveryKey = try RecoveryKey(parsing: typed)
            guard try await drive.isRecoveryKey(recoveryKey) else { throw DriveAccessError.wrongRecoveryKey }
        } else {
            recoveryKey = RecoveryKey()
            try RecoveryKeyNotice.show(recoveryKey, replacing: true)
        }
        try await drive.remove(target.id, recoveryKey: recoveryKey)
        let left = devices.filter { $0.approved && $0.id != target.id }.count
        print(
            "✓ Removed “\(target.name)”. The drive has a new key, held by \(left) device\(left == 1 ? "" : "s") "
                + "and the recovery key.")
    }
}

struct Unlock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Give this device the drive's keys with the recovery key.",
        discussion: """
            For when no other device can approve this one (or you'd rather not wait). The recovery key is the one shown when the drive was created, or by `atdrive recovery-key` since.
            """)

    func run() async throws {
        let context = try await Context.locked()
        if (try? await context.drive.unlock()) != nil {
            print("This device already has the drive's keys.")
            return
        }
        try await KeySetup.unlockWithRecoveryKey(context.drive)
    }
}

struct NewRecoveryKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery-key", abstract: "Make a new recovery key. The old one stops working.")

    func run() async throws {
        let drive = try await Context.load().drive
        guard Prompt.confirm("Make a new recovery key? The current one stops working.") else { return }
        // Shown before it's in effect, so it never is without having been seen.
        let recoveryKey = RecoveryKey()
        try RecoveryKeyNotice.show(recoveryKey, replacing: true)
        try await drive.replaceRecoveryKey(with: recoveryKey)
        print("✓ The new recovery key is in effect.")
    }
}

/// Getting this device the drive's keys, after signing in (`atdrive login`, `atdrive unlock`).
enum KeySetup {
    /// Opens the drive on this device; creates it if the account has none (showing its recovery
    /// key); or, for a drive this device has no keys for, asks for them: from another device, or
    /// with the recovery key.
    static func run() async throws {
        let context = try await Context.locked()
        let drive = context.drive
        do {
            try await drive.unlock()
            print("✓ This device has the drive's keys.")
            return
        } catch DriveAccessError.noDrive {
            let recoveryKey: RecoveryKey
            do {
                recoveryKey = try await drive.create()
            } catch DriveAccessError.driveExists {
                return try await run()  // another device made it a moment ago
            }
            print("✓ Created your drive. It's encrypted: only your devices can read it.")
            try RecoveryKeyNotice.show(recoveryKey, replacing: false)
            return
        } catch let error as DriveAccessError {
            switch error {
            case .notApproved, .untrustedKeyring, .keyringMissingKeys: break
            default: throw error
            }
            if case .notApproved = error {} else { Output.warn(error.description) }
        }
        try await join(drive)
    }

    /// For a drive this device has no keys for: approval from another device, or the recovery key.
    static func join(_ drive: Drive) async throws {
        guard Prompt.isInteractive else {
            if (try? await drive.arrivedKeyring()) == nil { try await drive.requestAccess() }
            throw ValidationError(
                "this device doesn't have the drive's keys. Run `atdrive login` in a terminal to compare "
                    + "codes with a device that has them, or `atdrive unlock` with the recovery key")
        }
        print(
            """

            This account's drive is encrypted, and this device doesn't have its keys yet. Either:
              1. approve it from a device that has them (compare a code on both), or
              2. type the recovery key.
            """)
        let choice = Prompt.line("Choose 1 or 2 [1]: ")?.trimmingCharacters(in: .whitespaces)
        if choice == "2" { return try await unlockWithRecoveryKey(drive) }
        try await waitForApproval(drive)
    }

    static func unlockWithRecoveryKey(_ drive: Drive) async throws {
        guard let text = Prompt.secret("Recovery key: ") else { throw ValidationError("no recovery key given") }
        try await drive.unlock(recoveryKey: try RecoveryKey(parsing: text))
        print("✓ This device has the drive's keys now.")
    }

    /// Asks for the keys, shows this device's codes, and waits until a keyring arrives whose
    /// sender's code the user confirms.
    static func waitForApproval(_ drive: Drive) async throws {
        guard let me = drive.identity else { throw DriveAccessError.locked }
        if (try? await drive.arrivedKeyring()) == nil { try await drive.requestAccess() }
        let approvers = try await drive.devices().filter { $0.approved && !$0.isThisDevice }
        print(
            """

            This device (“\(me.name)”, \(me.id)) is asking for the drive's keys. On a device that has
            them, run:

              atdrive devices approve \(me.name.contains(" ") ? me.id : me.name)

            It shows a code. This device's code with each of them:
            """)
        let width = approvers.map(\.name.count).max() ?? 0
        for device in approvers {
            print("  \(device.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(try device.pairingCode(with: me))")
        }
        if approvers.isEmpty { print("  (no device has them: use the recovery key, `atdrive unlock`)") }
        print("\nWaiting for approval… (Ctrl-C to stop; `atdrive login` again picks up from here)")

        var ignored: Set<String> = []
        while true {
            let arrived: ArrivedKeyring?
            do {
                arrived = try await drive.arrivedKeyring()
            } catch let error as DriveAccessError {
                if case .untrustedKeyring = error, ignored.insert(error.description).inserted {
                    Output.warn(error.description)
                }
                arrived = nil
            }
            if let arrived {
                print(
                    """

                    “\(arrived.sender.name)” approved this device. Its code:

                      \(arrived.code)

                    """)
                if Prompt.confirm("Is it the same as “\(arrived.sender.name)” showed?") {
                    try await drive.accept(arrived)
                    print("✓ This device has the drive's keys now.")
                    return
                }
                print("Not accepted. Asking again; approve it again from a device you trust.")
                try await drive.requestAccess()
            }
            try await Task.sleep(for: .seconds(3))
        }
    }
}

/// Shows a recovery key once, with what it's for.
enum RecoveryKeyNotice {
    static func show(_ key: RecoveryKey, replacing: Bool) throws {
        print(
            """

            \(replacing ? "The drive's new recovery key" : "Your drive's recovery key"):

                \(key.formatted)

            Write it down, or keep it in a password manager, now: it's shown only this once.
            With it, any device you sign in on can open the drive (`atdrive unlock`).
            If you lose every device that has the drive's keys and this key too, nobody can
            read your files again: not you, and not whoever runs your PDS.\(replacing ? "\nThe old recovery key stops working." : "")

            """)
        guard Prompt.isInteractive else {
            print("(Not asking you to confirm: there's no terminal. Save it now.)")
            return
        }
        while true {
            guard let answer = Prompt.line("Type yes once you've saved it: ") else {
                throw ValidationError("stopped before the recovery key was confirmed; it's above")
            }
            if answer.trimmingCharacters(in: .whitespaces).lowercased() == "yes" { return }
        }
    }
}

/// Questions on the terminal.
enum Prompt {
    static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 }

    /// A line from standard input, after showing `prompt`; `nil` at the end of input.
    static func line(_ prompt: String) -> String? {
        FileHandle.standardOutput.write(Data(prompt.utf8))
        return readLine()
    }

    /// Like `line`, without echoing what's typed when on a terminal.
    static func secret(_ prompt: String) -> String? {
        guard isInteractive else { return line(prompt) }
        guard let typed = getpass(prompt) else { return nil }
        return String(cString: typed)
    }

    /// Yes or no; no unless the answer starts with y.
    static func confirm(_ question: String) -> Bool {
        guard isInteractive else { return false }
        return line("\(question) [y/N] ")?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y") ?? false
    }
}

/// The one device named `name` (or with that ID) among `devices`.
private func pick(_ name: String, from devices: [DeviceInfo], describing place: String) throws -> DeviceInfo {
    if let byID = devices.first(where: { $0.id == name }) { return byID }
    let named = devices.filter { $0.name == name }
    switch named.count {
    case 1: return named[0]
    case 0: throw ValidationError("no device “\(name)” \(place) (see `atdrive devices`)")
    default:
        throw ValidationError(
            "several devices are called “\(name)”; use an ID: \(named.map(\.id).joined(separator: ", "))")
    }
}

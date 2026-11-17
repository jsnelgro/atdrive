import ATDriveCore
import ArgumentParser
import Foundation

struct Encryption: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Whether the drive is encrypted, and turning encryption on or off.",
        discussion: """
            A drive isn't encrypted unless you turn encryption on. Unencrypted, whoever runs your PDS can read your files and their names, and there are no keys to look after or lose. Encrypted, only devices that hold the drive's keys can read it: each new device has to be approved, and losing every device and the recovery key loses the drive.

            You can switch either way at any time. Turning it on uploads every file again, encrypted. Turning it off is immediate.
            """,
        subcommands: [EncryptionStatusCommand.self, EncryptionOn.self, EncryptionOff.self],
        defaultSubcommand: EncryptionStatusCommand.self
    )
}

struct EncryptionStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show whether the drive is encrypted, and what's left to convert.")

    func run() async throws {
        let drive = try await Context.load().drive
        EncryptionReport.show(try await drive.encryptionStatus())
    }
}

struct EncryptionOn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on", abstract: "Encrypt the drive, or finish encrypting it.",
        discussion: """
            Makes new keys (and shows a recovery key once), then encrypts what's in the drive: every file is downloaded and uploaded again, history included. That can take a long time and a lot of transfer on a big drive. It can be interrupted: run it again to pick up where it stopped.

            Your other devices have to be approved again afterwards (`atdrive login` there).

            Whoever runs your PDS has been able to read everything that's in the drive up to now. Encrypting protects it from here on, not from copies already made.
            """)

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() async throws {
        let drive = try await Context.locked(makingIdentity: true).drive
        let mode = try await drive.open()
        var adopt = false
        if mode == .plain {
            let status = try await drive.conversionEstimate(to: .encrypted)
            print(
                """
                Turning encryption on:
                  - Every file is uploaded again, encrypted: \(Output.size(status.pendingBytes)) in \(status.pending) record\(status.pending == 1 ? "" : "s"), history included.
                    It can be interrupted; `atdrive encryption on` again picks up where it stopped.
                  - You get a recovery key to keep safe. Lose it and every device that has the
                    drive's keys, and nobody can read the drive again.
                  - Your other devices must be approved again before they can use the drive.
                  - Whoever runs your PDS could read what's there until now. This protects it from
                    here on, not from copies already made.
                """)
            guard yes || Prompt.confirm("Turn encryption on?") else { return }
            let recoveryKey = try await drive.enableEncryption()
            print("✓ The drive is encrypted from now on.")
            try RecoveryKeyNotice.show(recoveryKey, replacing: false)
        } else {
            let status = try await drive.encryptionStatus()
            if status.isSettled && status.unsealed == 0 {
                print("The drive is encrypted, and nothing is left to convert.")
                return
            }
            if status.unsealed > 0 && !status.converting {
                print(
                    """
                    \(status.unsealed) record\(status.unsealed == 1 ? " isn't" : "s aren't") encrypted with the drive's keys, so your devices ignore \(status.unsealed == 1 ? "it" : "them").
                    A device that hadn't noticed encryption was turned on may have written \(status.unsealed == 1 ? "it" : "them"). So
                    could the server.
                    """)
                adopt = yes || Prompt.confirm("Encrypt and keep \(status.unsealed == 1 ? "it" : "them")?")
                if !adopt && status.pending == 0 { return }
            }
        }
        try await EncryptionReport.convert(drive, adoptUnsealed: adopt)
    }
}

struct EncryptionOff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Stop encrypting the drive, or finish decrypting it.",
        discussion: """
            Publishes the drive's keys in the drive itself, so everything in it, history included, becomes readable by whoever runs your PDS. That's immediate, and can't be taken back for what's already there. The drive's devices and recovery key are forgotten: any device signed in to your account can use the drive.

            Afterwards the records are rewritten as plain ones (files are uploaded again, unencrypted), so apps that can't decrypt can read them. That part can be skipped (--keep-records) or interrupted; run `atdrive encryption off` again to pick it up.
            """)

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    @Flag(help: "Only turn encryption off: leave what's there as it's stored, readable with the published keys.")
    var keepRecords = false

    func run() async throws {
        let drive = try await Context.load().drive
        if drive.mode == .encrypted {
            print(
                """
                Turning encryption off:
                  - Whoever runs your PDS will be able to read everything in the drive, history
                    included. This can't be taken back for what's already there.
                  - The drive's devices and its recovery key are forgotten. Any device signed in to
                    your account can use the drive.
                """)
            guard yes || Prompt.confirm("Turn encryption off?") else { return }
            try await drive.disableEncryption()
            print("✓ The drive isn't encrypted any more.")
        }
        if keepRecords { return }
        try await EncryptionReport.convert(drive, adoptUnsealed: false)
    }
}

enum EncryptionReport {
    static func show(_ status: EncryptionStatus) {
        switch status.mode {
        case .plain:
            print("The drive isn't encrypted: whoever runs your PDS can read it.")
            if status.pending > 0 {
                print(
                    "\(status.pending) record\(status.pending == 1 ? " is" : "s are") still stored encrypted "
                        + "(\(Output.size(status.pendingBytes)) of files), readable with the keys the drive "
                        + "published. `atdrive encryption off` rewrites them.")
            }
        case .encrypted:
            print("The drive is encrypted: only devices that hold its keys can read it.")
            if status.pending > 0 {
                print(
                    "\(status.pending) record\(status.pending == 1 ? " isn't" : "s aren't") encrypted yet "
                        + "(\(Output.size(status.pendingBytes)) of files). `atdrive encryption on` finishes the job.")
            } else if status.converting {
                print("Everything is encrypted. `atdrive encryption on` finishes turning it on.")
            }
            if status.unsealed > 0 {
                print(
                    "\(status.unsealed) record\(status.unsealed == 1 ? " isn't" : "s aren't") encrypted with the "
                        + "drive's keys and \(status.unsealed == 1 ? "is" : "are") ignored (see `atdrive encryption on`)."
                )
            }
        }
        if status.unreadable > 0 {
            print("\(status.unreadable) record\(status.unreadable == 1 ? "" : "s") can't be read on this device.")
        }
    }

    /// Converts what's left, showing progress, then where things stand.
    static func convert(_ drive: Drive, adoptUnsealed: Bool) async throws {
        let status = try await drive.convert(adoptUnsealed: adoptUnsealed) { done, total in
            Output.status("Converting  \(done) / \(total) records")
        }
        Output.clearStatus()
        if status.pending == 0 {
            print("✓ Everything in the drive is stored \(status.mode == .encrypted ? "encrypted" : "unencrypted").")
        }
        if status.pending > 0 || status.unsealed > 0 || status.unreadable > 0 { show(status) }
    }
}

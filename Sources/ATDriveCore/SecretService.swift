import Foundation

/// Secrets in the Secret Service (freedesktop.org's API for keyrings: GNOME Keyring, KWallet,
/// KeePassXC…), through `secret-tool`, libsecret's command. Each is an item with the attributes
/// `service me.jsnelgro.atdrive` and `account <name>`.
///
/// `secret-tool` rather than linking libsecret, so `atdrive` stays one static binary that runs on
/// a server without libsecret or a desktop. Secrets go to it on standard input and come back on
/// standard output, never in its arguments, where other users could see them.
struct SecretToolBackend: SecretBackend {
    /// Runs `secret-tool` with `arguments`, `input` on standard input.
    typealias Runner = @Sendable (_ arguments: [String], _ input: Data?) throws -> SecretTool.Result

    let lockFile: URL
    let run: Runner
    var service = SecretStorage.service

    var description: String { "the Secret Service" }

    private func attributes(_ name: String) -> [String] { ["service", service, "account", name] }

    func read(_ name: String) throws -> Data? {
        let result = try run(["lookup"] + attributes(name), nil)
        if result.status == 0 { return result.output }
        if result.isNotFound { return nil }
        throw SecretServiceError.failed("read", name, result.error)
    }

    func write(_ data: Data, as name: String) throws {
        let result = try run(["store", "--label=ATDrive (\(name))"] + attributes(name), data)
        guard result.status == 0 else { throw SecretServiceError.failed("save", name, result.error) }
    }

    func delete(_ name: String) throws {
        let result = try run(["clear"] + attributes(name), nil)
        guard result.status == 0 || result.isNotFound else {
            throw SecretServiceError.failed("delete", name, result.error)
        }
    }
}

enum SecretTool {
    struct Result: Sendable {
        var status: Int32
        var output: Data
        var error: String

        /// `secret-tool` says nothing when there's no such item, only exiting with 1; anything
        /// else (no bus, no Secret Service, a locked keyring) comes with a message.
        var isNotFound: Bool { status == 1 && error.isEmpty }
    }

    /// How long to wait for it: unlocking a keyring can mean a prompt nobody is there to answer.
    static let timeout: TimeInterval = 30

    /// `secret-tool` on the `PATH`, if there's a session bus for it to find a Secret Service on.
    static func find(environment: [String: String]) -> SecretToolBackend.Runner? {
        let hasBus =
            environment["DBUS_SESSION_BUS_ADDRESS"].map { !$0.isEmpty }
            ?? environment["XDG_RUNTIME_DIR"].map { FileManager.default.fileExists(atPath: "\($0)/bus") } ?? false
        guard hasBus else { return nil }
        let paths = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        guard
            let tool = paths.map({ "\($0)/secret-tool" }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { return nil }
        return { arguments, input in try run(tool, arguments, input: input) }
    }

    static func run(_ tool: String, _ arguments: [String], input: Data?, timeout: TimeInterval = timeout) throws
        -> Result
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        // Stops one that's waiting on a prompt nobody answers.
        let running = RunningProcess(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { running.stop() }
        if let input { standardInput.fileHandleForWriting.write(input) }
        try? standardInput.fileHandleForWriting.close()
        // Small, both: the secret, or a line of error. Neither fills a pipe while the other waits.
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if running.stopped { throw SecretServiceError.timedOut(timeout) }
        return Result(
            status: process.terminationStatus, output: output,
            error: String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A process, for stopping it from another thread.
    private final class RunningProcess: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var didStop = false

        init(_ process: Process) { self.process = process }

        var stopped: Bool { lock.withLock { didStop } }

        func stop() {
            lock.withLock {
                guard process.isRunning else { return }
                didStop = true
                // SIGKILL, not terminate()'s SIGTERM: a child keeps a parent's ignored or blocked
                // signals, so SIGTERM can go unheard. Nothing's lost: it was only waiting.
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

public enum SecretServiceError: Error, CustomStringConvertible, Equatable {
    /// What failed, the secret's name, and what `secret-tool` said.
    case failed(String, String, String)
    /// After this many seconds.
    case timedOut(TimeInterval)
    /// They're in the Secret Service (this file says so), but it can't be reached from here.
    case unreachable(URL)

    public var description: String {
        switch self {
        case .failed(let operation, let name, let message):
            "couldn't \(operation) ATDrive's \(name) in the Secret Service: \(message.isEmpty ? "secret-tool failed" : message)"
        case .timedOut(let seconds):
            "the Secret Service didn't answer within \(Int(seconds)) seconds (is your keyring locked?)"
        case .unreachable(let file):
            "your session and keys are in the Secret Service, which isn't reachable from here: it needs secret-tool and a session bus (DBUS_SESSION_BUS_ADDRESS). To keep them in files instead, delete \(file.path) and sign in again"
        }
    }
}

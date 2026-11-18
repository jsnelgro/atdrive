import Foundation
import Testing

@testable import ATDriveCore

/// Where secrets go on Linux: the Secret Service where there is one, files where there isn't,
/// decided once; and what's left in files moving in.
@Suite struct SecretStorageTests {
    let directory: URL

    init() throws {
        directory = try temporaryDirectory().appendingPathComponent("state")
    }

    /// `secret-tool`, as far as these tests need: a keyring in memory, or one that can't be
    /// reached (no Secret Service on the bus).
    final class FakeSecretTool: @unchecked Sendable {
        private let lock = NSLock()
        var items: [String: Data] = [:]
        var reachable = true
        private(set) var calls = 0

        var runner: SecretToolBackend.Runner {
            { arguments, input in try self.run(arguments, input) }
        }

        private func run(_ arguments: [String], _ input: Data?) throws -> SecretTool.Result {
            try lock.withLock {
                calls += 1
                guard reachable else {
                    return SecretTool.Result(
                        status: 1, output: Data(),
                        error: "The name org.freedesktop.secrets was not provided by any .service files")
                }
                let account = try #require(arguments.last)
                #expect(Array(arguments.suffix(4)) == ["service", SecretStorage.service, "account", account])
                switch arguments[0] {
                case "lookup":
                    guard let data = items[account] else {
                        return SecretTool.Result(status: 1, output: Data(), error: "")
                    }
                    return SecretTool.Result(status: 0, output: data, error: "")
                case "store":
                    #expect(input != nil, "secrets go on standard input")
                    items[account] = input ?? Data()
                    return SecretTool.Result(status: 0, output: Data(), error: "")
                case "clear":
                    let existed = items.removeValue(forKey: account) != nil
                    return SecretTool.Result(status: existed ? 0 : 1, output: Data(), error: "")
                default:
                    Issue.record("unexpected \(arguments)")
                    return SecretTool.Result(status: 2, output: Data(), error: "?")
                }
            }
        }
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    var choice: String? {
        (try? String(contentsOf: directory.appendingPathComponent("storage"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theSecretServiceIsUsedWhereThereIsOne() throws {
        let tool = FakeSecretTool()
        let storage = SecretStorage.linux(directory: directory, secretTool: tool.runner)
        try storage.write(Data("token".utf8), as: "session")
        #expect(choice == "secret-service")
        #expect(tool.items["session"] == Data("token".utf8))
        #expect(!exists(file("session")))
        #expect(try storage.read("session") == Data("token".utf8))
        #expect(try storage.read("device") == nil)
        #expect(storage.description.contains("Secret Service"))
        try storage.delete("session")
        #expect(tool.items.isEmpty)
        try storage.delete("session")  // nothing to delete is fine
    }

    @Test func whatsInFilesMovesIn() throws {
        // Signed in before there was a Secret Service (or before this version).
        let files = SecretStorage.directory(directory)
        try files.write(Data("key".utf8), as: "device")
        try files.write(Data("old".utf8), as: "session")
        let tool = FakeSecretTool()
        let storage = SecretStorage.linux(directory: directory, secretTool: tool.runner)
        #expect(try storage.read("device") == Data("key".utf8))  // undecided: still the files

        // The first save decides, and takes everything along.
        try storage.write(Data("new".utf8), as: "session")
        #expect(tool.items == ["device": Data("key".utf8), "session": Data("new".utf8)])
        #expect(!exists(file("device")) && !exists(file("session")))
        #expect(try storage.read("device") == Data("key".utf8))
    }

    @Test func aFileLeftBehindMovesInWhenRead() throws {
        let tool = FakeSecretTool()
        let storage = SecretStorage.linux(directory: directory, secretTool: tool.runner)
        try storage.write(Data("token".utf8), as: "session")
        try SecretStorage.directory(directory).write(Data("key".utf8), as: "device")
        #expect(try storage.read("device") == Data("key".utf8))
        #expect(tool.items["device"] == Data("key".utf8))
        #expect(!exists(file("device")))
    }

    @Test func noSecretServiceMeansFilesFromThenOn() throws {
        let tool = FakeSecretTool()
        tool.reachable = false
        let storage = SecretStorage.linux(directory: directory, secretTool: tool.runner)
        try storage.write(Data("token".utf8), as: "session")
        #expect(choice == "files")
        #expect(exists(file("session")))
        #expect(try storage.read("session") == Data("token".utf8))
        // Not tried again: a server without a desktop doesn't pay for it on every save.
        let calls = tool.calls
        tool.reachable = true
        try storage.write(Data("token2".utf8), as: "session")
        #expect(tool.calls == calls)
        #expect(tool.items.isEmpty)
    }

    @Test func noSecretToolMeansFilesUntilThereIsOne() throws {
        let storage = SecretStorage.linux(directory: directory, secretTool: nil)
        try storage.write(Data("token".utf8), as: "session")
        #expect(choice == nil)
        #expect(try storage.read("session") == Data("token".utf8))
        let mode =
            try FileManager.default.attributesOfItem(atPath: file("session").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // Installed later: the next save moves them in.
        let tool = FakeSecretTool()
        try SecretStorage.linux(directory: directory, secretTool: tool.runner).write(Data("t2".utf8), as: "session")
        #expect(tool.items["session"] == Data("t2".utf8))
        #expect(!exists(file("session")))
    }

    @Test func anUnreachableSecretServiceIsAnErrorNotAQuietSwitch() throws {
        let tool = FakeSecretTool()
        try SecretStorage.linux(directory: directory, secretTool: tool.runner).write(Data("t".utf8), as: "session")
        // Later, somewhere without the session bus (over SSH, say).
        let elsewhere = SecretStorage.linux(directory: directory, secretTool: nil)
        #expect(throws: SecretServiceError.self) { try elsewhere.read("session") }
        // A locked or missing keyring says what it said.
        tool.reachable = false
        let error = try #require(throws: SecretServiceError.self) {
            try SecretStorage.linux(directory: directory, secretTool: tool.runner).read("session")
        }
        #expect("\(error)".contains("org.freedesktop.secrets"))
    }

    @Test func theSyncServiceGetsTheSameStorage() {
        let linux = SecretStorage.linux(
            directory: URL(fileURLWithPath: "/home/me/.local/state/atdrive"), secretTool: nil)
        #expect(linux.environment == ["XDG_STATE_HOME": "/home/me/.local/state"])
        let files = SecretStorage.directory(URL(fileURLWithPath: "/srv/secrets"))
        #expect(files.environment == ["ATDRIVE_STATE_DIR": "/srv/secrets"])
    }

    @Test func secretToolIsFoundOnlyWithASessionBus() throws {
        let bin = try temporaryDirectory()
        let tool = bin.appendingPathComponent("secret-tool")
        #expect(
            FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        #expect(SecretTool.find(environment: ["PATH": bin.path]) == nil)
        #expect(SecretTool.find(environment: ["PATH": bin.path, "DBUS_SESSION_BUS_ADDRESS": "unix:path=/x"]) != nil)
        #expect(SecretTool.find(environment: ["PATH": "/nowhere", "DBUS_SESSION_BUS_ADDRESS": "unix:path=/x"]) == nil)
    }

    @Test func secretToolGetsSecretsOnItsInputAndIsStoppedIfItHangs() throws {
        let bin = try temporaryDirectory()
        let echo = bin.appendingPathComponent("echo-tool")
        let hang = bin.appendingPathComponent("hang-tool")
        #expect(
            FileManager.default.createFile(
                atPath: echo.path, contents: Data("#!/bin/sh\ncat; echo \"$@\" >&2\nexit 3\n".utf8),
                attributes: [.posixPermissions: 0o755]))
        #expect(
            FileManager.default.createFile(
                atPath: hang.path, contents: Data("#!/bin/sh\nexec sleep 30\n".utf8),
                attributes: [.posixPermissions: 0o755]))
        let result = try SecretTool.run(echo.path, ["store", "a b"], input: Data("secret".utf8))
        #expect(result.output == Data("secret".utf8))
        #expect(result.error == "store a b")
        #expect(result.status == 3)
        let started = Date()
        #expect(throws: SecretServiceError.timedOut(0.5)) {
            try SecretTool.run(hang.path, ["lookup"], input: nil, timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// Against a real Secret Service: run where one is unlocked, e.g.
    ///
    ///     dbus-run-session -- sh -c 'echo pw | gnome-keyring-daemon --unlock --components=secrets >/dev/null; \
    ///       ATDRIVE_SECRET_SERVICE_TESTS=1 swift test --filter SecretStorageTests'
    ///
    /// It uses its own service name, so it never touches your ATDrive items.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ATDRIVE_SECRET_SERVICE_TESTS"] != nil))
    func aRealSecretService() throws {
        let runner = try #require(SecretTool.find(environment: ProcessInfo.processInfo.environment))
        let backend = SecretToolBackend(
            lockFile: directory.appendingPathComponent(".lock"), run: runner, service: "me.jsnelgro.atdrive.test")
        let secret = Data("{\n  \"line\": \"two\"\n}\u{00e9}".utf8)
        try backend.write(secret, as: "session")
        #expect(try backend.read("session") == secret)
        try backend.write(Data("again".utf8), as: "session")
        #expect(try backend.read("session") == Data("again".utf8))
        try backend.delete("session")
        #expect(try backend.read("session") == nil)
        try backend.delete("session")
    }
}

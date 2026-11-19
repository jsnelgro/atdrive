import Foundation
import Testing

@testable import ATDriveCore

/// `config.toml` (read, and edited in place) and where secrets are kept instead.
@Suite struct ConfigTests {
    let directory: URL

    init() throws {
        directory = try temporaryDirectory()
    }

    func configFile(_ text: String? = nil) throws -> ConfigFile {
        let file = ConfigFile(url: directory.appendingPathComponent("atdrive/config.toml"))
        if let text {
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file.url)
        }
        return file
    }

    func text(_ file: ConfigFile) throws -> String { try String(contentsOf: file.url, encoding: .utf8) }

    // MARK: Reading

    @Test func noFileMeansTheDefaults() throws {
        let loaded = try configFile().loadInDetail()
        #expect(loaded.config == LocalConfig())
        #expect(!loaded.exists)
        #expect(loaded.entries.map(\.key) == ["sync.interval", "apps.enabled", "apps.spotlight"])
        #expect(loaded.entries.allSatisfy { !$0.isSet })
    }

    @Test func readsSettings() throws {
        let file = try configFile(
            """
            # mine
            [sync]
            interval = 60  # a minute
            """)
        let loaded = try file.loadInDetail()
        #expect(loaded.config.syncInterval == 60)
        #expect(loaded.entries.first?.isSet == true)
        #expect(loaded.unknownKeys.isEmpty)
    }

    @Test func dottedKeysWorkToo() throws {
        let config = try configFile("sync.interval = 1_200\n").load()
        #expect(config.syncInterval == 1200)
    }

    @Test func theAppsViewIsOffUnlessTurnedOn() throws {
        #expect(!LocalConfig().appsEnabled)
        #expect(!LocalConfig().appsSpotlight)
        let config = try configFile("[apps]\nenabled = true\nspotlight = true\n").load()
        #expect(config.appsEnabled)
        #expect(config.appsSpotlight)
        let wrong = try configFile("[apps]\nenabled = \"yes\"\n")
        let error = try #require(throws: ConfigError.self) { try wrong.load() }
        #expect(error.message.contains("true or false"))

        let file = try configFile("[sync]\ninterval = 60\n")
        try file.update { $0.appsEnabled = true }
        #expect(try file.load().appsEnabled)
        #expect(try file.load().syncInterval == 60)
    }

    @Test func reportsKeysItDoesntKnow() throws {
        let loaded = try configFile("[sync]\nintervl = 60\n[later]\nthing = 'x'\n").loadInDetail()
        #expect(loaded.unknownKeys == ["later.thing", "sync.intervl"])
        #expect(loaded.config == LocalConfig())
    }

    @Test func wrongValuesSayWhere() throws {
        let file = try configFile("\n[sync]\ninterval = \"60\"\n")
        let error = try #require(throws: ConfigError.self) { try file.load() }
        #expect(error.line == 3)
        #expect(error.message.contains("whole number"))
        let tooShort = try configFile("[sync]\ninterval = 1\n")
        #expect(throws: ConfigError.self) { try tooShort.load() }
    }

    @Test func badSyntaxSaysWhere() throws {
        for (text, line) in [
            ("[sync\n", 1), ("a = \n", 1), ("\n\nb = nope\n", 3), ("a = 1\na = 2\n", 2),
            ("[t]\n[t]\n", 2), ("a = \"open\n", 1), ("a = 1 2\n", 1),
        ] {
            let file = try configFile(text)
            let error = try #require(throws: ConfigError.self) { try file.load() }
            #expect(error.line == line, "\(text.debugDescription)")
        }
    }

    @Test func unsupportedTOMLIsSaidToBe() throws {
        for text in [
            "a = [1, 2]", "a = { b = 1 }", "[[a]]", "a = 1979-05-27", "\"a\" = 1", "a = \"\"\"x\"\"\"", "a = 0xff",
        ] {
            let file = try configFile(text)
            let error = try #require(throws: ConfigError.self) { try file.load() }
            #expect(error.message.contains("aren't supported"), "\(text)")
        }
    }

    // MARK: TOML values

    @Test func valuesParse() throws {
        let document = try TOMLDocument(
            parsing: """
                a = "tab\\there \\"q\\" \\u00e9" # comment
                b = 'C:\\path'
                c = -17
                d = +3.5e2
                e = true
                f = false
                g = 0
                h = 1e3
                i = "# not a comment"
                """)
        #expect(document.value("a") == .string("tab\there \"q\" é"))
        #expect(document.value("b") == .string("C:\\path"))
        #expect(document.value("c") == .integer(-17))
        #expect(document.value("d") == .float(350))
        #expect(document.value("e") == .boolean(true))
        #expect(document.value("f") == .boolean(false))
        #expect(document.value("g") == .integer(0))
        #expect(document.value("h") == .float(1000))
        #expect(document.value("i") == .string("# not a comment"))
        #expect(throws: TOMLError.self) { try TOMLDocument(parsing: "a = 01") }
        #expect(throws: TOMLError.self) { try TOMLDocument(parsing: "a = 1__0") }
    }

    @Test func valuesWriteBackAsTheyRead() throws {
        for value: TOMLDocument.Value in [
            .string("plain"), .string("q\"uo\\te\n\t\u{1}"), .integer(-3), .float(0.25), .float(-.infinity),
            .boolean(true),
        ] {
            var document = try TOMLDocument(parsing: "")
            document.set("t.k", to: value)
            let reread = try TOMLDocument(parsing: document.text)
            #expect(reread.value("t.k") == value)
        }
    }

    // MARK: Editing

    @Test func savingMakesTheFileWithAHeader() throws {
        let file = try configFile()
        try file.update { $0.syncInterval = 45 }
        let saved = try text(file)
        #expect(saved.hasPrefix("# ATDrive's settings"))
        #expect(saved.hasSuffix("\n\n[sync]\ninterval = 45\n"))
        #expect(try file.load().syncInterval == 45)
    }

    @Test func savingWhatsAlreadyThereWritesNothing() throws {
        let file = try configFile()
        try file.update { $0.syncInterval = LocalConfig().syncInterval }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func savingChangesOnlyTheValue() throws {
        let original = """
            # my settings
            [sync]
            # how often
            interval   =   30   # seconds

            [other]
            keep = 'me'

            """
        let file = try configFile(original)
        try file.update { $0.syncInterval = 300 }
        #expect(try text(file) == original.replacingOccurrences(of: "=   30   #", with: "=   300   #"))
    }

    @Test func savingAddsToTheTableThatsThere() throws {
        let file = try configFile("[sync]\n# nothing yet\n\n[other]\nkeep = 1\n")
        try file.update { $0.syncInterval = 60 }
        #expect(try text(file) == "[sync]\ninterval = 60\n# nothing yet\n\n[other]\nkeep = 1\n")
    }

    @Test func savingKeepsWindowsLineEndings() throws {
        let file = try configFile("# hi\r\n[sync]\r\ninterval = 30\r\n")
        try file.update { $0.syncInterval = 15 }
        #expect(try text(file) == "# hi\r\n[sync]\r\ninterval = 15\r\n")
    }

    @Test func savingRefusesAFileItCantRead() throws {
        let broken = "[sync\ninterval = 30\n"
        let file = try configFile(broken)
        #expect(throws: ConfigError.self) { try file.update { $0.syncInterval = 60 } }
        #expect(try text(file) == broken)
        #expect(throws: ConfigError.self) { try configFile().update { $0.syncInterval = 1 } }
    }

    // MARK: Where things are

    @Test func configLivesInTheConfigFolder() {
        #expect(ConfigFile.standard(environment: ["ATDRIVE_CONFIG_DIR": "/x"]).url.path == "/x/config.toml")
        #expect(
            ConfigFile.standard(environment: ["XDG_CONFIG_HOME": "/xdg"]).url.path == "/xdg/atdrive/config.toml")
        #expect(ConfigFile.standard(environment: [:]).url.path.hasSuffix("/.config/atdrive/config.toml"))
        #expect(
            ConfigFile.inHome(URL(fileURLWithPath: "/Users/me")).url.path == "/Users/me/.config/atdrive/config.toml")
    }

    @Test func secretsNeverLiveInTheConfigFolder() {
        let state = SecretStorage.standard(environment: ["ATDRIVE_STATE_DIR": "/s"])
        #expect(state.directory?.path == "/s")
        #expect(SecretStorage.defaultDirectory(environment: ["XDG_STATE_HOME": "/st"]).path == "/st/atdrive")
        #expect(SecretStorage.defaultDirectory(environment: [:]).path.hasSuffix("/.local/state/atdrive"))
        // Not even when the config folder is moved (the old variable named both).
        let moved = SecretStorage.standard(environment: ["ATDRIVE_CONFIG_DIR": "/c", "XDG_CONFIG_HOME": "/xdg"])
        #expect(moved.directory?.path.hasPrefix("/c") != true)
        #expect(moved.directory?.path.hasPrefix("/xdg") != true)
        #if os(macOS)
            #expect(moved.directory == nil)  // the Keychain
        #else
            #expect(moved.directory?.path.hasSuffix("/.local/state/atdrive") == true)
        #endif
    }

    @Test func sessionsAreSavedPrivately() throws {
        let storage = SecretStorage.directory(directory.appendingPathComponent("state"))
        let store = SessionStore(storage: storage)
        #expect(try store.load() == nil)
        let session = Session(
            did: "did:plc:me", handle: "me.test", service: URL(string: "https://pds.test")!, accessJwt: "a",
            refreshJwt: "r",
            oauth: OAuthInfo(
                issuer: "https://pds.test", tokenEndpoint: URL(string: "https://pds.test/token")!,
                revocationEndpoint: nil, clientID: "c", dpopKey: Data([1, 2]), expiresAt: nil))
        try store.save(session)
        #expect(try store.load() == session)
        let file = directory.appendingPathComponent("state/session.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let folderMode =
            try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions]
            as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        #expect(folderMode?.intValue == 0o700)
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()  // nothing to delete is fine
    }
}

import Foundation
import Testing

@testable import ATDriveCore

/// One session used by several processes (the Mac app, its Finder extension, the `atdrive`
/// inside the app): a refresh token works only once, so they mustn't each refresh with it.
@Suite struct SharedSessionTests {
    let store: SessionStore
    let session = Session(
        did: "did:plc:test", handle: "alice.test", service: URL(string: "https://pds.test")!,
        accessJwt: "old-access", refreshJwt: "old-refresh",
        oauth: OAuthInfo(
            issuer: "https://auth.test", tokenEndpoint: URL(string: "https://auth.test/token")!,
            revocationEndpoint: nil, clientID: "http://localhost", dpopKey: DPoPKey().rawRepresentation,
            expiresAt: nil))

    init() throws {
        store = SessionStore(directory: try temporaryDirectory().appendingPathComponent("state"))
        try store.save(session)
    }

    static let expired = (401, #"{"error":"invalid_token","message":"Token has expired"}"#, [String: String]())
    static let ok = (200, #"{"value":1}"#, [String: String]())

    struct Output: Decodable { var value: Int }

    @Test func aProcessTakesTheTokensAnotherRefreshedTo() async throws {
        // The app refreshes first, and saves what it got.
        let app = ScriptedTransport([
            Self.expired,
            (
                200,
                #"{"access_token":"new-access","token_type":"DPoP","refresh_token":"new-refresh","sub":"did:plc:test","expires_in":3600}"#,
                [:]
            ),
            Self.ok,
        ])
        let appManager = SessionManager(session, store: store, transport: app)
        let _: Output = try await XRPCClient(service: session.service, session: appManager, transport: app)
            .query("com.example.thing")
        #expect(try store.load()?.refreshJwt == "new-refresh")

        // The extension still holds the old tokens. Its access token expires too: it takes the
        // app's new ones instead of refreshing with a refresh token that no longer works.
        let ext = ScriptedTransport([Self.expired, Self.ok])
        let extManager = SessionManager(session, store: store, transport: ext)
        let _: Output = try await XRPCClient(service: session.service, session: extManager, transport: ext)
            .query("com.example.thing")
        #expect(ext.requests.allSatisfy { $0.url != session.oauth.tokenEndpoint })
        #expect(
            ext.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "DPoP old-access", "DPoP new-access",
            ])
        #expect(await extManager.session.refreshJwt == "new-refresh")
    }

    @Test func takenTokensThatHaveExpiredAreRefreshed() async throws {
        // Another process refreshed long ago; its access token has expired since.
        var older = session
        older.accessJwt = "other-access"
        older.refreshJwt = "other-refresh"
        older.oauth.expiresAt = Date().addingTimeInterval(-10)
        try store.save(older)

        let transport = ScriptedTransport([
            Self.expired,
            (
                200,
                #"{"access_token":"newest-access","token_type":"DPoP","refresh_token":"newest-refresh","sub":"did:plc:test"}"#,
                [:]
            ),
            Self.ok,
        ])
        let manager = SessionManager(session, store: store, transport: transport)
        let _: Output = try await XRPCClient(service: session.service, session: manager, transport: transport)
            .query("com.example.thing")
        // Refreshed with the saved refresh token, not its own spent one.
        let form = String(decoding: transport.requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("refresh_token=other-refresh"))
        #expect(try store.load()?.refreshJwt == "newest-refresh")
    }

    @Test func anotherAccountsSessionIsntTaken() async throws {
        var other = session
        other.did = "did:plc:someone-else"
        other.refreshJwt = "their-refresh"
        try store.save(other)
        let transport = ScriptedTransport([
            Self.expired,
            (
                200,
                #"{"access_token":"new-access","token_type":"DPoP","refresh_token":"new-refresh","sub":"did:plc:test"}"#,
                [:]
            ),
            Self.ok,
        ])
        let manager = SessionManager(session, store: store, transport: transport)
        let _: Output = try await XRPCClient(service: session.service, session: manager, transport: transport)
            .query("com.example.thing")
        let form = String(decoding: transport.requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("refresh_token=old-refresh"))
    }

    @Test func theCommandInsideTheAppFindsItsGroup() throws {
        let root = try temporaryDirectory()
        let contents = root.appendingPathComponent("ATDrive.app/Contents")
        let helpers = contents.appendingPathComponent("Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let executable = helpers.appendingPathComponent("atdrive")
        try Data().write(to: executable)
        // Without an Info.plist that names a group, it's not the app's.
        #expect(SecretStorage.enclosingAppGroup(executable: executable) == nil)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["ATDriveAppGroup": "TEAM123456.me.jsnelgro.atdrive"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(SecretStorage.enclosingAppGroup(executable: executable) == "TEAM123456.me.jsnelgro.atdrive")
        // Run through a link on the PATH.
        let link = root.appendingPathComponent("bin/atdrive")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        #expect(SecretStorage.enclosingAppGroup(executable: link) == "TEAM123456.me.jsnelgro.atdrive")
        // A command built on its own isn't the app's.
        #expect(SecretStorage.enclosingAppGroup(executable: root.appendingPathComponent("build/atdrive")) == nil)

        let shared = SecretStorage.appGroup(container: root.appendingPathComponent("group"))
        #expect(shared.isSharedWithApp)
        #expect(shared.directory?.path.hasSuffix("group/Library/Application Support/ATDrive") == true)
    }

    @Test func oneRefreshAtATime() async throws {
        actor Overlap {
            var active = 0
            var most = 0
            func enter() {
                active += 1
                most = max(most, active)
            }
            func leave() { active -= 1 }
        }
        let overlap = Overlap()
        // Each with its own open file, as separate processes would have.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { [store] in
                    try await store.storage.withLock {
                        await overlap.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        await overlap.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await overlap.most == 1)
    }
}

import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The whole sign-in: OAuth against `FakeAuthorizationServer`, then the passkey unlock against
/// `FakePDS`, with `FakeUnlockPage` standing in for the browser's unlock page.
@Suite struct SignInTests {
    let auth = FakeAuthorizationServer()
    let pds = FakePDS()
    let transport: Router
    let resolver: IdentityResolver
    /// Nothing listens here: a browser following the app's redirect to the unlock page gets no
    /// further than the address, which is all `FakeUnlockPage` needs.
    let environment = ["ATDRIVE_UNLOCK_PAGE": "http://127.0.0.1:9/unlock/"]
    let page = FakeUnlockPage(credentialID: "Y3JlZC0x", prf: Data(repeating: 3, count: 32))

    init() {
        transport = Router(auth: auth, pds: pds)
        resolver = IdentityResolver(environment: ["ATDRIVE_PLC_URL": "https://plc.test"], transport: transport)
    }

    /// The browser approves sign-in, and the app sends it on to the unlock page and back.
    @Test func inTheBrowser() async throws {
        let first = try await signInWithBrowser()
        let key = try #require(first.driveKey)
        #expect(first.did == "did:plc:alice")
        #expect(pds.rawRecord(Lexicon.key, DriveUnlock.firstKeyRecord) != nil)

        // Next time, the same passkey unlocks the same drive.
        let second = try await signInWithBrowser(expectMode: "unlock")
        #expect(second.driveKey == key)
    }

    /// From a remote machine: the user pastes each address the browser ends up on.
    @Test func withPastedAddresses() async throws {
        let shown = Box<[SignIn.Step: URL]>([:])
        let auth = auth
        let page = page
        let session = try await SignIn.run(
            identifier: "did:plc:alice", resolver: resolver, environment: environment, transport: transport,
            timeout: 30,
            open: { url, step in shown.update { $0[step] = url } },
            paste: { step in
                switch step {
                case .signIn:
                    return "127.0.0.1:9/?iss=https%3A%2F%2Fpds.test&state=\(auth.lastPAR["state"]!)&code=the-code"
                case .unlock:
                    return try page.answer(try #require(shown.value[.unlock(alreadyOpen: false)]))
                }
            })
        #expect(session.driveKey != nil)
        #expect(Set(shown.value.keys) == [.signIn, .unlock(alreadyOpen: false)])
    }

    @Test func aPasskeyThatCantUnlockFails() async throws {
        _ = try await signInWithBrowser()
        let impostor = FakeUnlockPage(credentialID: "Y3JlZC0x", prf: Data(repeating: 4, count: 32))
        await #expect(throws: ATDriveError.self) {
            _ = try await signInWithBrowser(expectMode: "unlock", page: impostor)
        }
    }

    private func signInWithBrowser(expectMode: String = "create", page: FakeUnlockPage? = nil) async throws
        -> Session
    {
        let page = page ?? self.page
        let auth = auth
        let browser = Box<Task<String, Error>?>(nil)
        let session = try await SignIn.run(
            identifier: "did:plc:alice", resolver: resolver, environment: environment, transport: transport,
            timeout: 30,
            open: { url, step in
                switch step {
                case .signIn:
                    // Approved: the PDS sends the browser back to the app, which sends it on to
                    // the unlock page, which sends it back to the app.
                    browser.value = Task {
                        let redirect =
                            auth.lastPAR["redirect_uri"]! + "?iss=https%3A%2F%2Fpds.test"
                            + "&state=\(auth.lastPAR["state"]!)&code=the-code"
                        let unlockPage = try await Browser.location(after: redirect)
                        let request = try page.request(unlockPage)
                        #expect(request["mode"] == expectMode)
                        if expectMode == "unlock" { #expect(request["creds"] == page.credentialID) }
                        return try await Browser.load(try page.answer(unlockPage))
                    }
                case .unlock(let alreadyOpen):
                    #expect(alreadyOpen)
                }
            })
        let finalPage = try await browser.value!.value
        #expect(finalPage.contains("Your drive is unlocked"))
        return session
    }
}

/// Sends drive requests to `FakePDS` and the rest to `FakeAuthorizationServer`.
struct Router: HTTPTransport {
    let auth: FakeAuthorizationServer
    let pds: FakePDS

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.url!.lastPathComponent
        if method.hasPrefix("com.atproto.space.") || method == "com.atproto.repo.uploadBlob" {
            return try await pds.send(request)
        }
        return try await auth.send(request)
    }
}

/// A browser, as far as the app's 127.0.0.1 listener can tell.
enum Browser {
    /// Loads an address and returns where it redirects to.
    static func location(after url: String) async throws -> URL {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let (_, response) = try await session.data(from: URL(string: url)!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 303)
        return try #require((http.value(forHTTPHeaderField: "Location")).flatMap(URL.init(string:)))
    }

    static func load(_ url: String) async throws -> String {
        let (data, _) = try await URLSessionTransport().send(URLRequest(url: URL(string: url)!))
        return String(decoding: data, as: UTF8.self)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// A value shared with `@Sendable` closures.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

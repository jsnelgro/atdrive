import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// atproto OAuth: sign in through your PDS's own web page, so ATDrive never sees your password.
///
/// The flow (https://atproto.com/specs/oauth): find the account's authorization server from its
/// PDS, push the request (PAR) with PKCE and a DPoP key, open the sign-in page in the browser,
/// catch the redirect on a local port, and swap the code for DPoP-bound tokens.
///
/// ATDrive is a "native" public client. With no web server of its own it uses atproto's
/// loopback client ID (`http://localhost?scope=…`), which needs no hosted metadata. Set
/// `ATDRIVE_OAUTH_CLIENT_ID` to the URL of hosted client metadata to use that instead (it must
/// list `http://127.0.0.1/` as a redirect URI). Either way, the PDS ends sessions for public
/// clients after two weeks, after which you sign in again.
public enum OAuthLogin {
    /// What ATDrive asks for. Override with `ATDRIVE_OAUTH_SCOPE`.
    ///
    /// - Writes: only ATDrive's records (nodes, their versions, and the drive's settings), and
    ///   creating spaces.
    /// - Reads: spaces your account owns.
    /// - Blob uploads: needed for file contents.
    ///
    /// The scope names spaces with `*`, not ATDrive's own space type, because naming a type
    /// makes the PDS look up that type's published lexicon to show on the consent screen, and
    /// `me.jsnelgro.atdrive.drive` isn't published yet. Once it is (DNS TXT record at
    /// `_lexicon.atdrive.jsnelgro.me`, plus the schema records), switch to `narrowScope`.
    public static func scope(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let configured = environment["ATDRIVE_OAUTH_SCOPE"], !configured.isEmpty { return configured }
        return "atproto space:*?\(collections)&manage=create blob:*/*"
    }

    /// The scope to use once ATDrive's lexicons are published: access to ATDrive's spaces only.
    public static let narrowScope = "atproto space:\(Lexicon.driveSpace)?\(collections)&manage=create blob:*/*"

    private static let collections = [Lexicon.node, Lexicon.version, Lexicon.settings].map { "collection=\($0)" }
        .joined(separator: "&")

    public static func clientID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let configured = environment["ATDRIVE_OAUTH_CLIENT_ID"], !configured.isEmpty { return configured }
        return "http://localhost?scope=\(FormEncoding.escape(scope(environment: environment)))"
    }

    /// The whole sign-in: `open` should show the URL in a browser. Returns once the user has
    /// approved access there (or throws if they declined, it timed out, or the task was cancelled).
    ///
    /// When the browser is on another device (signing in on a remote server over SSH), its
    /// redirect to 127.0.0.1 can't reach this machine; the page fails to load, but its address
    /// holds the result. Pass `pastedRedirect` to accept that address from the user as well:
    /// whichever arrives first wins. (The code in it is useless without this process's PKCE
    /// verifier and DPoP key, so pasting it is safe.)
    public static func signIn(
        identifier: String, resolver: IdentityResolver = IdentityResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 600,
        open: @Sendable (URL) async throws -> Void,
        pastedRedirect: (@Sendable () async throws -> String)? = nil
    ) async throws -> Session {
        let listener = try LoopbackServer()
        let pending = try await prepare(
            identifier: identifier, redirectURI: "http://127.0.0.1:\(listener.port)/", resolver: resolver,
            environment: environment, transport: transport)
        try await open(pending.authorizationURL)
        let params: [String: String]
        if let pastedRedirect {
            params = try await Race<[String: String]>().first(
                { try await listener.waitForRedirect(timeout: timeout) },
                orUnlessItFails: { try redirectParameters(fromPasted: try await pastedRedirect()) })
        } else {
            params = try await listener.waitForRedirect(timeout: timeout)
        }
        return try await pending.complete(with: params, transport: transport)
    }

    /// The sign-in result from an address the user copied out of their browser
    /// (`http://127.0.0.1:53251/?iss=…&state=…&code=…`, with or without the `http://`).
    public static func redirectParameters(fromPasted text: String) throws -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question = trimmed.firstIndex(of: "?"),
            let url = URLComponents(string: "http://127.0.0.1/" + trimmed[question...]),
            let items = url.queryItems
        else { throw ATDriveError.loginFailed("that isn't the address from the browser") }
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard params["state"] != nil, params["code"] != nil || params["error"] != nil else {
            throw ATDriveError.loginFailed("that isn't the address from the browser")
        }
        return params
    }

    /// Steps 1–2: resolve the account, find its authorization server, and push the request.
    public static func prepare(
        identifier: String, redirectURI: String, resolver: IdentityResolver = IdentityResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> PendingAuthorization {
        let identity = try await resolver.resolve(identifier)
        let server = try await AuthorizationServer.discover(pds: identity.pds, transport: transport)
        let clientID = clientID(environment: environment)
        let key = DPoPKey()
        let verifier = Base64URL.random(bytes: 32)
        let state = Base64URL.random(bytes: 16)

        let (data, nonce) = try await server.post(
            to: server.pushedAuthorizationRequestEndpoint,
            [
                ("client_id", clientID),
                ("response_type", "code"),
                ("response_mode", "query"),
                ("redirect_uri", redirectURI),
                ("scope", scope(environment: environment)),
                ("state", state),
                ("code_challenge", Base64URL.encode(SHA256.hash(data: Data(verifier.utf8)))),
                ("code_challenge_method", "S256"),
                ("login_hint", identity.handle ?? identity.did),
            ], key: key, nonce: nil, transport: transport)
        struct Output: Decodable { var request_uri: String }
        let requestURI = try JSONDecoder().decode(Output.self, from: data).request_uri

        var url = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        url.percentEncodedQuery = FormEncoding.encode([("client_id", clientID), ("request_uri", requestURI)])
        return PendingAuthorization(
            authorizationURL: url.url!, identity: identity, server: server, clientID: clientID,
            redirectURI: redirectURI, state: state, verifier: verifier, key: key, nonce: nonce)
    }
}

/// A sign-in waiting for the user to approve it in the browser.
public struct PendingAuthorization: Sendable {
    /// Open this in a browser.
    public let authorizationURL: URL
    let identity: ResolvedIdentity
    let server: AuthorizationServer
    let clientID: String
    let redirectURI: String
    let state: String
    let verifier: String
    let key: DPoPKey
    let nonce: String?

    /// Step 3: exchange the redirect's code for tokens.
    public func complete(with params: [String: String], transport: any HTTPTransport = URLSessionTransport())
        async throws -> Session
    {
        guard params["state"] == state else { throw ATDriveError.loginFailed("unexpected sign-in response") }
        if let error = params["error"] {
            throw ATDriveError.loginFailed(params["error_description"] ?? error)
        }
        if let issuer = params["iss"], issuer != server.issuer {
            throw ATDriveError.loginFailed("response came from \(issuer), expected \(server.issuer)")
        }
        guard let code = params["code"] else { throw ATDriveError.loginFailed("no authorization code") }

        let (data, _) = try await server.post(
            to: server.tokenEndpoint,
            [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirectURI),
                ("client_id", clientID),
                ("code_verifier", verifier),
            ], key: key, nonce: nonce, transport: transport)
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        // The server must be the one for the account we asked about.
        guard tokens.sub == identity.did else {
            throw ATDriveError.identity("signed in as \(tokens.sub), expected \(identity.did)")
        }
        guard let refreshToken = tokens.refresh_token else {
            throw ATDriveError.loginFailed("the server didn't issue a refresh token")
        }
        return Session(
            did: identity.did, handle: identity.handle ?? identity.did, service: identity.pds,
            accessJwt: tokens.access_token, refreshJwt: refreshToken,
            oauth: OAuthInfo(
                issuer: server.issuer, tokenEndpoint: server.tokenEndpoint,
                revocationEndpoint: server.revocationEndpoint, clientID: clientID,
                dpopKey: key.rawRepresentation, expiresAt: tokens.expiresAt))
    }
}

/// What an OAuth session needs besides its tokens, saved alongside them.
public struct OAuthInfo: Codable, Sendable, Equatable {
    public var issuer: String
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL?
    public var clientID: String
    /// The DPoP private key the tokens are bound to.
    public var dpopKey: Data
    public var expiresAt: Date?
}

struct TokenResponse: Decodable {
    var access_token: String
    var token_type: String
    var refresh_token: String?
    var expires_in: Double?
    var sub: String

    var expiresAt: Date? { expires_in.map { Date().addingTimeInterval($0) } }
}

/// An OAuth error response: `{"error": "invalid_grant", "error_description": "…"}`.
public struct OAuthError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let error: String?
    public let errorDescription: String?

    init(status: Int, body: Data) {
        struct Payload: Decodable {
            var error: String?
            var error_description: String?
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: body)
        self.status = status
        error = payload?.error
        errorDescription = payload?.error_description
    }

    public var description: String {
        let detail = [error, errorDescription].compactMap { $0 }.joined(separator: ": ")
        return "\(detail.isEmpty ? "OAuth request failed" : detail) (HTTP \(status))"
    }
}

/// The account's OAuth authorization server (usually the PDS itself).
struct AuthorizationServer: Sendable {
    var issuer: String
    var pushedAuthorizationRequestEndpoint: URL
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var revocationEndpoint: URL?

    static func discover(pds: URL, transport: any HTTPTransport) async throws -> AuthorizationServer {
        struct Resource: Decodable { var authorization_servers: [String] }
        let resource: Resource = try await fetchJSON(
            pds.appendingPathComponent(".well-known/oauth-protected-resource"), transport: transport)
        guard let issuer = resource.authorization_servers.first, let issuerURL = URL(string: issuer) else {
            throw ATDriveError.identity("\(pds.host ?? "the PDS") doesn't support OAuth sign-in")
        }
        struct Metadata: Decodable {
            var issuer: String
            var pushed_authorization_request_endpoint: URL
            var authorization_endpoint: URL
            var token_endpoint: URL
            var revocation_endpoint: URL?
        }
        let metadata: Metadata = try await fetchJSON(
            issuerURL.appendingPathComponent(".well-known/oauth-authorization-server"), transport: transport)
        guard metadata.issuer == issuer else {
            throw ATDriveError.identity("authorization server \(metadata.issuer) doesn't match \(issuer)")
        }
        return AuthorizationServer(
            issuer: metadata.issuer, pushedAuthorizationRequestEndpoint: metadata.pushed_authorization_request_endpoint,
            authorizationEndpoint: metadata.authorization_endpoint, tokenEndpoint: metadata.token_endpoint,
            revocationEndpoint: metadata.revocation_endpoint)
    }

    /// POSTs a form with a DPoP proof, retrying once if the server hands out a fresh nonce.
    /// Returns the body and the latest nonce, to use on the next request.
    func post(
        to url: URL, _ fields: [(String, String)], key: DPoPKey?, nonce: String?, transport: any HTTPTransport
    ) async throws -> (Data, String?) {
        try await Self.post(to: url, fields, key: key, nonce: nonce, transport: transport)
    }

    static func post(
        to url: URL, _ fields: [(String, String)], key: DPoPKey?, nonce: String?, transport: any HTTPTransport
    ) async throws -> (Data, String?) {
        var nonce = nonce
        var retried = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode(fields).utf8)
            if let key {
                request.setValue(try key.proof(method: "POST", url: url, nonce: nonce), forHTTPHeaderField: "DPoP")
            }
            let (data, response) = try await transport.send(request)
            let latest = response.header("DPoP-Nonce") ?? nonce
            if (200..<300).contains(response.statusCode) { return (data, latest) }
            let error = OAuthError(status: response.statusCode, body: data)
            if error.error == "use_dpop_nonce", !retried, latest != nonce {
                nonce = latest
                retried = true
                continue
            }
            throw error
        }
    }

    private static func fetchJSON<T: Decodable>(_ url: URL, transport: any HTTPTransport) async throws -> T {
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard response.statusCode == 200 else {
            throw ATDriveError.identity("couldn't load \(url.absoluteString) (HTTP \(response.statusCode))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ATDriveError.unexpectedResponse("\(url.absoluteString): \(error)")
        }
    }
}

/// `application/x-www-form-urlencoded`, escaping everything but unreserved characters.
enum FormEncoding {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    static func escape(_ value: String) -> String {
        value.utf8.map { unreserved.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }
            .joined()
    }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

/// Waits on two ways of getting the same result and takes the first. The first operation's
/// failure (e.g. a timeout) ends the wait; the second's is ignored (e.g. stdin closed).
private final class Race<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    func first(
        _ primary: @escaping @Sendable () async throws -> Value,
        orUnlessItFails secondary: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled before we got here: nothing else will resume this.
                let cancelledAlready = lock.withLock { () -> Bool in
                    if finished { return true }
                    self.continuation = continuation
                    return false
                }
                if cancelledAlready { return continuation.resume(throwing: CancellationError()) }
                let tasks = [
                    Task { self.finish(await Result { try await primary() }) },
                    Task { if let value = try? await secondary() { self.finish(.success(value)) } },
                ]
                let alreadyFinished = lock.withLock {
                    self.tasks = tasks
                    return finished
                }
                if alreadyFinished { tasks.forEach { $0.cancel() } }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        let (continuation, tasks): (CheckedContinuation<Value, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            defer { self.continuation = nil }
            return (self.continuation, self.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

extension Result where Failure == Error {
    fileprivate init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

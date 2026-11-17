import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A logged-in account: who it is, which server (PDS) hosts it, and its OAuth tokens (DPoP-bound).
/// Signing in is always OAuth (`OAuthLogin.signIn`): atproto spaces refuse app passwords.
public struct Session: Codable, Sendable, Equatable {
    public var did: String
    public var handle: String
    /// The account's PDS, from its DID document. Never hardcoded.
    public var service: URL
    /// OAuth access token.
    public var accessJwt: String
    /// OAuth refresh token.
    public var refreshJwt: String
    public var oauth: OAuthInfo

    public init(did: String, handle: String, service: URL, accessJwt: String, refreshJwt: String, oauth: OAuthInfo) {
        self.did = did
        self.handle = handle
        self.service = service
        self.accessJwt = accessJwt
        self.refreshJwt = refreshJwt
        self.oauth = oauth
    }
}

/// Owns the live session: signs each request (DPoP for OAuth), keeps the servers' DPoP nonces,
/// swaps in fresh tokens when the access token expires (once, even if many requests notice at
/// the same moment), and reports each change so it can be saved.
public actor SessionManager {
    public private(set) var session: Session
    private let onChange: @Sendable (Session) -> Void
    private let transport: any HTTPTransport
    private var refreshing: Task<Session, Error>?
    /// Latest DPoP nonce per server origin.
    private var nonces: [String: String] = [:]

    public init(
        _ session: Session, transport: any HTTPTransport = URLSessionTransport(),
        onChange: @escaping @Sendable (Session) -> Void = { _ in }
    ) {
        self.session = session
        self.transport = transport
        self.onChange = onChange
    }

    /// Headers that authenticate a request to the PDS, and the access token they use.
    func authorization(method: String, url: URL) async throws -> (headers: [String: String], token: String) {
        let oauth = session.oauth
        if let expiry = oauth.expiresAt, expiry.timeIntervalSinceNow < 30 {
            try await refresh(expiredAccessToken: session.accessJwt)
        }
        let token = session.accessJwt
        let key = try DPoPKey(rawRepresentation: oauth.dpopKey)
        let proof = try key.proof(method: method, url: url, nonce: nonces[Self.origin(url)], accessToken: token)
        return (["Authorization": "DPoP \(token)", "DPoP": proof], token)
    }

    /// Remembers the nonce a server sent, for the next proof. Returns true if it changed.
    @discardableResult
    func observe(_ response: HTTPURLResponse, for url: URL) -> Bool {
        guard let nonce = response.header("DPoP-Nonce"), nonces[Self.origin(url)] != nonce else { return false }
        nonces[Self.origin(url)] = nonce
        return true
    }

    func refresh(expiredAccessToken: String) async throws {
        // Someone else already refreshed since this request was sent.
        guard session.accessJwt == expiredAccessToken else { return }
        let task: Task<Session, Error>
        if let refreshing {
            task = refreshing
        } else {
            let current = session
            let nonce = nonces[Self.origin(current.oauth.tokenEndpoint)]
            let transport = transport
            task = Task { try await Self.refreshedOAuth(current, nonce: nonce, transport: transport) }
            refreshing = task
        }
        let updated: Session
        do {
            updated = try await task.value
            refreshing = nil
        } catch {
            refreshing = nil  // let the next caller try again
            throw error
        }
        if session != updated {
            session = updated
            onChange(updated)
        }
    }

    private static func refreshedOAuth(_ session: Session, nonce: String?, transport: any HTTPTransport)
        async throws -> Session
    {
        let oauth = session.oauth
        let data: Data
        do {
            (data, _) = try await AuthorizationServer.post(
                to: oauth.tokenEndpoint,
                [
                    ("grant_type", "refresh_token"), ("refresh_token", session.refreshJwt),
                    ("client_id", oauth.clientID),
                ],
                key: try DPoPKey(rawRepresentation: oauth.dpopKey), nonce: nonce, transport: transport)
        } catch let error as OAuthError where error.error == "invalid_grant" {
            // Sessions for apps like this one end after two weeks; time to sign in again.
            throw ATDriveError.sessionEnded
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        var updated = session
        updated.accessJwt = tokens.access_token
        updated.refreshJwt = tokens.refresh_token ?? session.refreshJwt
        updated.oauth.expiresAt = tokens.expiresAt
        return updated
    }

    private static func origin(_ url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
    }
}

public enum Auth {
    /// Revokes the session on the server (best effort).
    public static func logout(_ session: Session, transport: any HTTPTransport = URLSessionTransport()) async {
        guard let revocation = session.oauth.revocationEndpoint else { return }
        _ = try? await AuthorizationServer.post(
            to: revocation, [("token", session.refreshJwt), ("client_id", session.oauth.clientID)],
            key: nil, nonce: nil, transport: transport)
    }
}

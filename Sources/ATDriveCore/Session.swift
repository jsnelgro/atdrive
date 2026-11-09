import Foundation

/// A logged-in account: who it is, which server (PDS) hosts it, and its tokens.
public struct Session: Codable, Sendable, Equatable {
    public var did: String
    public var handle: String
    /// The account's PDS, from its DID document. Never hardcoded.
    public var service: URL
    public var accessJwt: String
    public var refreshJwt: String

    public init(did: String, handle: String, service: URL, accessJwt: String, refreshJwt: String) {
        self.did = did
        self.handle = handle
        self.service = service
        self.accessJwt = accessJwt
        self.refreshJwt = refreshJwt
    }
}

/// Owns the live session: swaps in fresh tokens when the access token expires (once, even if
/// many requests notice at the same moment) and reports each change so it can be saved.
public actor SessionManager {
    public private(set) var session: Session
    private let onChange: @Sendable (Session) -> Void
    private var refreshing: Task<Session, Error>?

    public init(_ session: Session, onChange: @escaping @Sendable (Session) -> Void = { _ in }) {
        self.session = session
        self.onChange = onChange
    }

    func refresh(expiredAccessToken: String, client: XRPCClient) async throws {
        // Someone else already refreshed since this request was sent.
        guard session.accessJwt == expiredAccessToken else { return }
        let task: Task<Session, Error>
        if let refreshing {
            task = refreshing
        } else {
            let current = session
            task = Task { try await Self.refreshed(current, client: client) }
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

    private static func refreshed(_ session: Session, client: XRPCClient) async throws -> Session {
        let data = try await client.send(
            "com.atproto.server.refreshSession", body: (Data(), "application/json"),
            auth: .bearer(session.refreshJwt))
        let tokens = try JSONDecoder().decode(SessionTokens.self, from: data)
        var updated = session
        updated.accessJwt = tokens.accessJwt
        updated.refreshJwt = tokens.refreshJwt
        updated.handle = tokens.handle
        return updated
    }
}

struct SessionTokens: Decodable {
    var did: String
    var handle: String
    var accessJwt: String
    var refreshJwt: String
}

public enum Auth {
    /// Logs in with a handle (or DID) and a password. Use an app password: it works everywhere
    /// ATDrive needs and can be revoked without changing your real password.
    public static func login(
        identifier: String, password: String, resolver: IdentityResolver,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> Session {
        let identity = try await resolver.resolve(identifier)
        let client = XRPCClient(service: identity.pds, transport: transport)
        struct Input: Encodable {
            var identifier: String
            var password: String
        }
        let data: Data
        do {
            data = try await client.send(
                "com.atproto.server.createSession",
                body: (
                    try XRPCClient.encoder.encode(
                        Input(identifier: identity.handle ?? identity.did, password: password)),
                    "application/json"
                ),
                auth: .none)
        } catch let error as XRPCError where error.error == "AuthenticationRequired" {
            throw ATDriveError.loginFailed(error.message ?? "invalid identifier or password")
        }
        let tokens = try JSONDecoder().decode(SessionTokens.self, from: data)
        guard tokens.did == identity.did else {
            throw ATDriveError.identity("server logged in \(tokens.did), expected \(identity.did)")
        }
        return Session(
            did: tokens.did, handle: tokens.handle, service: identity.pds,
            accessJwt: tokens.accessJwt, refreshJwt: tokens.refreshJwt)
    }

    /// Revokes the session on the server (best effort).
    public static func logout(_ session: Session, transport: any HTTPTransport = URLSessionTransport()) async {
        let client = XRPCClient(service: session.service, transport: transport)
        _ = try? await client.send(
            "com.atproto.server.deleteSession", body: (Data(), "application/json"),
            auth: .bearer(session.refreshJwt))
    }
}

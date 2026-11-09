import Foundation

/// An app password as the PDS lists it. The password itself is only shown once, when created.
public struct AppPassword: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var createdAt: String
    public var privileged: Bool?

    public var id: String { name }
    public var createdDate: Date? { Timestamp.parse(createdAt) }
}

/// A just-created app password, including the password (the only time it's available).
public struct NewAppPassword: Codable, Sendable, Equatable {
    public var name: String
    public var password: String
    public var createdAt: String
}

/// Lists, creates and revokes the account's app passwords.
///
/// The PDS only allows this with a session started from the account's main password: it refuses
/// OAuth sessions (like ATDrive's) and app-password sessions. So `unlock` takes that password and
/// starts a temporary session, and `lock` ends it. The password itself isn't kept.
public struct AppPasswordManager: Sendable {
    private let client: XRPCClient
    private let sessionManager: SessionManager

    /// Starts a temporary full-access session for `account` (an existing, e.g. OAuth, session:
    /// it says which account and PDS) using the account's main password.
    public static func unlock(
        account: Session, password: String, transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> AppPasswordManager {
        struct Input: Encodable {
            var identifier: String
            var password: String
        }
        let data: Data
        do {
            data = try await XRPCClient(service: account.service, transport: transport).send(
                "com.atproto.server.createSession",
                body: (
                    try XRPCClient.encoder.encode(Input(identifier: account.did, password: password)),
                    "application/json"
                ),
                auth: .none)
        } catch let error as XRPCError where error.error == "AuthenticationRequired" {
            throw ATDriveError.loginFailed("wrong password")
        } catch let error as XRPCError where error.error == "AuthFactorTokenRequired" {
            throw ATDriveError.loginFailed(
                "your account needs an emailed sign-in code, which ATDrive doesn't support yet")
        }
        let tokens = try JSONDecoder().decode(SessionTokens.self, from: data)
        guard tokens.did == account.did else {
            throw ATDriveError.identity("signed in as \(tokens.did), expected \(account.did)")
        }
        let session = Session(
            did: tokens.did, handle: tokens.handle, service: account.service,
            accessJwt: tokens.accessJwt, refreshJwt: tokens.refreshJwt)
        // An app password also starts a session, but one that can't manage app passwords.
        guard Self.scope(of: tokens.accessJwt) == "com.atproto.access" else {
            await Auth.logout(session, transport: transport)
            throw ATDriveError.loginFailed(
                "that's an app password; managing app passwords needs your account password")
        }
        let manager = SessionManager(session, transport: transport)
        return AppPasswordManager(
            client: XRPCClient(service: account.service, session: manager, transport: transport),
            sessionManager: manager)
    }

    /// Newest first.
    public func list() async throws -> [AppPassword] {
        struct Output: Decodable { var passwords: [AppPassword] }
        return try await client.query("com.atproto.server.listAppPasswords", as: Output.self).passwords
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func create(name: String) async throws -> NewAppPassword {
        struct Input: Encodable { var name: String }
        return try await client.procedure("com.atproto.server.createAppPassword", Input(name: name))
    }

    /// Anything signed in with it stops working.
    public func revoke(name: String) async throws {
        struct Input: Encodable { var name: String }
        let _: XRPCClient.Empty = try await client.procedure("com.atproto.server.revokeAppPassword", Input(name: name))
    }

    /// Ends the temporary session.
    public func lock() async {
        await Auth.logout(await sessionManager.session, transport: client.transport)
    }

    /// The `scope` claim of an atproto access JWT (not verified: only used to explain a refusal).
    static func scope(of jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return claims["scope"] as? String
    }
}

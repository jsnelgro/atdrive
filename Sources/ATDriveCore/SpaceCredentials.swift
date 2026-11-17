import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Reads a space owned by another account (0016, "Credential flow"), the way a member, or anyone
/// with a public link, does:
///
/// 1. The reader's own PDS signs a delegation token for the space (`getDelegationToken`). Skipped
///    signed out: only a public space lets that through.
/// 2. The space's host trades it for a credential (`authorizeSpaceSync`), bound to a fresh P-256
///    key, good for about 10 minutes.
/// 3. Each read carries the credential and a signature with that key (`SpaceRequestSigner`), and
///    commits come back with a MAC this checks (`SpaceMAC`).
///
/// A credential the host stops taking (expired, or revoked) is renewed once; if that fails too,
/// the error is the host's (`SpaceNotFound` for a non-member, `SpaceDeleted` for a deleted space).
public actor SpaceCredentials {
    public let space: String
    /// The space's authority: the account that owns it.
    public let authority: String
    /// The authority's PDS, which issues credentials and (for read-only shares) holds the repo.
    public let host: URL
    /// A delegation token for the space from the reader's own PDS; `nil` when signed out.
    let delegation: (@Sendable (String) async throws -> String)?
    let resolver: IdentityResolver
    let transport: any HTTPTransport
    private var current: (credential: String, signer: SpaceRequestSigner, expires: Date)?
    private var renewing: Task<(String, SpaceRequestSigner, Date), Error>?
    private var kemKeys: [String: P256.KeyAgreement.PublicKey] = [:]

    public init(
        space: String, host: URL, delegation: (@Sendable (String) async throws -> String)?,
        resolver: IdentityResolver, transport: any HTTPTransport = URLSessionTransport()
    ) throws {
        guard let parts = XRPCClient.spaceParts(space) else { throw ATDriveError.invalidLink(space) }
        self.space = space
        authority = parts.authority
        self.host = host
        self.delegation = delegation
        self.resolver = resolver
        self.transport = transport
    }

    /// A client for reading the space at its host, with this credential.
    public nonisolated var client: XRPCClient { XRPCClient(service: host, credentials: self, transport: transport) }

    /// The headers for a request whose audience is `audience` (the DID whose repo is read, or the
    /// authority for the host's own methods). `renew` gets a new credential first.
    func headers(audience: String, renew: Bool) async throws -> [String: String] {
        let (credential, signer) = try await credential(renew: renew)
        return try signer.headers(credential: credential, audience: audience)
    }

    private func credential(renew: Bool) async throws -> (String, SpaceRequestSigner) {
        if !renew, let current, current.expires.timeIntervalSinceNow > 30 {
            return (current.credential, current.signer)
        }
        let task: Task<(String, SpaceRequestSigner, Date), Error>
        if let renewing {
            task = renewing
        } else {
            let space = space
            let delegation = delegation
            let client = XRPCClient(service: host, transport: transport)
            task = Task {
                // A new key for each credential (0016, "Credential key binding").
                let signer = SpaceRequestSigner()
                let token = try await delegation?(space)
                let credential = try await client.authorizeSpaceSync(
                    space: space, credentialKey: signer.didKey, delegationToken: token)
                return (credential, signer, Self.expiry(of: credential))
            }
            renewing = task
        }
        defer { renewing = nil }
        let (credential, signer, expires) = try await task.value
        current = (credential, signer, expires)
        return (credential, signer)
    }

    /// When a credential (a JWT) expires: its `exp`, or 10 minutes from now if it doesn't say.
    static func expiry(of credential: String) -> Date {
        let parts = credential.split(separator: ".")
        if parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let exp = claims["exp"] as? Double
        {
            return Date(timeIntervalSince1970: exp)
        }
        return Date().addingTimeInterval(10 * 60)
    }

    /// The KEM key of the account whose repo is read, from its DID document (cached).
    func kemKey(of did: String, refresh: Bool = false) async throws -> P256.KeyAgreement.PublicKey {
        if !refresh, let key = kemKeys[did] { return key }
        guard let key = try await resolver.resolveDID(did).kemKey else { throw SpaceAuthError.noKEMKey(did) }
        kemKeys[did] = key
        return key
    }

    /// Errors that mean the credential wasn't taken, so a new one may help.
    static func isCredentialRefused(_ error: XRPCError) -> Bool {
        error.status == 401
            || ["InvalidCredential", "ExpiredCredential", "CredentialRevoked", "InvalidToken", "ExpiredToken"]
                .contains(error.error ?? "")
    }

    /// Methods whose responses carry a commit, and so a MAC.
    static let committing: Set<String> = ["com.atproto.space.getLatestCommit", "com.atproto.space.listRepoOps"]
}

/// What a reader can tell about a space it can't read.
public enum SpaceAccessProblem: Error, Equatable, CustomStringConvertible {
    /// It isn't shared with this account, or it doesn't exist: the host doesn't say which.
    case notShared
    /// Its owner deleted it.
    case deleted
    /// Its owner's account is taken down or deactivated: it may come back.
    case suspended(String)
    /// Its owner's PDS refused this app (`allowedApps`).
    case appNotAllowed

    /// What a host's error says about the space; `nil` if it says nothing (network trouble, say).
    public init?(_ error: Error) {
        if let problem = error as? SpaceAccessProblem {
            self = problem
            return
        }
        guard let error = error as? XRPCError else { return nil }
        switch error.error {
        case "SpaceNotFound", "RepoNotFound", "AccountNotAuthorized", "NotAuthorized", "InvalidDelegationToken":
            self = .notShared
        case "SpaceDeleted": self = .deleted
        case "RepoTakendown", "RepoDeactivated", "RepoSuspended": self = .suspended(error.error!)
        case "AppNotAuthorized": self = .appNotAllowed
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .notShared: "it isn't shared with you, or it no longer exists"
        case .deleted: "its owner deleted it"
        case .suspended: "its owner's account is suspended or deactivated for now"
        case .appNotAllowed: "its owner allows only other apps to read it"
        }
    }
}

/// Where the signed-in account (or nobody, signed out) reads other accounts' spaces from: makes a
/// `SpaceCredentials` for a space, finding its host from its authority's DID.
public struct SpaceAccess: Sendable {
    /// The signed-in account's own PDS, for delegation tokens; `nil` signed out.
    public let ownClient: XRPCClient?
    public let resolver: IdentityResolver
    public let transport: any HTTPTransport

    public init(ownClient: XRPCClient?, resolver: IdentityResolver, transport: any HTTPTransport = URLSessionTransport())
    {
        self.ownClient = ownClient
        self.resolver = resolver
        self.transport = transport
    }

    public func credentials(for space: String) async throws -> SpaceCredentials {
        guard let parts = XRPCClient.spaceParts(space) else { throw ATDriveError.invalidLink(space) }
        let host = try await resolver.resolve(parts.authority).pds
        var delegation: (@Sendable (String) async throws -> String)?
        if let client = ownClient {
            delegation = { @Sendable space in try await client.getDelegationToken(space: space) }
        }
        return try SpaceCredentials(
            space: space, host: host, delegation: delegation, resolver: resolver, transport: transport)
    }
}

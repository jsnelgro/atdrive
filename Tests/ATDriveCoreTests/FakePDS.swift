import Crypto
import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An in-memory stand-in for the PDS endpoints ATDrive uses, so the drive logic (chunking,
/// encryption, verification, paging, following the change feed, sharing) can be tested without a
/// network. Behaviour against the real server is checked by `LiveTests`.
///
/// It hosts any number of accounts (`addAccount`; `did:plc:test` is there from the start), each
/// with repos in any number of spaces, its public repo, its DID document (with a KEM key) and its
/// handle, all on `https://pds.test`. Requests act as `did:plc:test` unless they come through an
/// account's transport (`as`). Most helpers take the default drive (`FakePDS.space`, the test
/// account's repo in it) unless told otherwise.
///
/// Like the reference PDS, every write gets a revision (a TID) and is logged with its index
/// in the commit, its CID and the CID it replaced; `listRepoOps` serves that log with a value
/// only for ops whose version is still current, and the current commit on every page.
///
/// Spaces have policies: `personalspace`, or `memberspace` with members, `publicRead` and
/// `publicWrite` (which lets anyone write their repo in it: invites, #68). Other
/// accounts read them as the protocol says: a delegation token from their own PDS, a credential
/// from `authorizeSpaceSync`, then reads that carry it with a request signature (checked), and
/// MACs on commits. A member removed, or a space deleted, has its credentials revoked at once.
///
/// Blobs are garbage-collected as a PDS does: a blob lives while a record references it, and
/// goes when the last one does; one never referenced goes after a few commits (`blobGrace`). So
/// history that doesn't keep its chunks loses them, and a test notices.
final class FakePDS: HTTPTransport, @unchecked Sendable {
    static let defaultDID = "did:plc:test"

    private struct Stored {
        var cid: String
        var json: Data
        /// The blobs it references.
        var blobs: Set<String>
    }
    private struct Op {
        var rev: String
        var idx: Int
        var collection: String
        var rkey: String
        var cid: String?
        var prev: String?
    }
    private struct Repo {
        /// By `collection/rkey`.
        var records: [String: Stored] = [:]
        var oplog: [Op] = []
        /// `nil` until its first write.
        var rev: String?
    }
    private struct RepoKey: Hashable {
        var space: String
        var did: String
    }
    private struct SpaceState {
        var authority: String
        var policy: SpacePolicy
        var members: [String: SpaceMember] = [:]
        var deleted = false
    }
    private struct Account {
        var handle: String
        var kem = P256.KeyAgreement.PrivateKey()
    }
    private struct Credential {
        var space: String
        var reader: String?
        var key: P256.Signing.PublicKey
        var expires: Date
    }

    private let lock = NSLock()
    private var accounts: [String: Account] = [FakePDS.defaultDID: Account(handle: "test.test")]
    private var spaces: [String: SpaceState] = [:]
    private var repos: [RepoKey: Repo] = [:]
    /// Public repos: DID → `collection/rkey` → record.
    private var publicRecords: [String: [String: Stored]] = [:]
    private var credentials: [String: Credential] = [:]
    private var delegationTokens: [String: (did: String, space: String)] = [:]
    private(set) var blobs: [String: Data] = [:]
    /// Blobs uploaded and not referenced yet → the commit count when they were uploaded.
    private var unreferencedSince: [String: Int] = [:]
    private var commitCount = 0
    /// How many commits a blob nothing references yet survives (an upload in progress).
    var blobGrace = 10
    /// Blobs garbage-collected so far.
    private(set) var collectedBlobs: Set<String> = []
    private(set) var calls: [String] = []
    /// Flip a byte in every blob served, to simulate corruption.
    var corruptDownloads = false
    /// Records per listRecords page, to exercise paging.
    var pageSize = 2
    /// The most ops per listRepoOps page (the client's limit applies too), to exercise paging.
    var opsPageSize = 3
    /// Fail the next calls to these methods (e.g. `com.atproto.space.getBlob`) with a 500.
    var failing: [String: Int] = [:]
    /// Let this many more calls to these methods through, then fail every one after with a 500:
    /// a transfer cut off partway.
    var failingAfter: [String: Int] = [:]
    /// Serve this many more commits (`Int.max`: every one) with a `data` that matches no
    /// records, as a server that hashes differently would.
    var lyingCommits = 0
    /// How long each request takes, so requests sent at once overlap.
    var latency: Duration?
    /// The most bytes an `applyWrites` request may have, as a real PDS limits it.
    var requestLimit: Int?
    /// How long a credential lasts.
    var credentialLifetime: TimeInterval = 600
    /// Spaces whose policy lets only other apps in (`allowedApps`): `authorizeSpaceSync` says
    /// `AppNotAuthorized`.
    var refusingApps: Set<String> = []
    /// Lexicons `com.atproto.lexicon.resolveLexicon` finds, by NSID (the schema record).
    var lexicons: [String: [String: Any]] = [:]
    /// MAC commits with someone else's key, as a host that isn't the owner's would.
    var forgeMACs = false
    /// The biggest `applyWrites` request so far, in bytes.
    private(set) var biggestTransaction = 0
    /// The most requests that were being handled at once.
    private(set) var mostAtOnce = 0
    private var atOnce = 0

    /// The default drive's repo.
    private static let defaultKey = RepoKey(space: FakePDS.space, did: FakePDS.defaultDID)

    var spaceExists: Bool { lock.withLock { spaces[Self.space].map { !$0.deleted } ?? false } }
    var recordCount: Int { lock.withLock { repos[Self.defaultKey]?.records.count ?? 0 } }
    /// The default drive's current revision.
    var revision: String? { lock.withLock { repos[Self.defaultKey]?.rev } }
    var opCount: Int { lock.withLock { repos[Self.defaultKey]?.oplog.count ?? 0 } }

    /// How many calls to `method` there have been.
    func count(_ method: String) -> Int { lock.withLock { calls.filter { $0 == method }.count } }
    /// How many blobs were uploaded, and fetched.
    var uploads: Int { count("com.atproto.repo.uploadBlob") }
    var downloads: Int { count("com.atproto.space.getBlob") }

    /// Forgets the calls so far, so a test can count from here.
    func resetCounts() {
        lock.withLock {
            calls = []
            mostAtOnce = 0
        }
    }

    /// Called with each method name before it's handled (e.g. to change something mid-sync).
    var onRequest: (@Sendable (String) -> Void)?

    // MARK: Accounts

    /// Adds an account (`did:plc:<name>`, handle `<name>.test`) and returns its DID.
    @discardableResult
    func addAccount(_ name: String) -> String {
        let did = "did:plc:\(name)"
        lock.withLock { accounts[did] = accounts[did] ?? Account(handle: "\(name).test") }
        return did
    }

    /// A transport that makes requests as `did`'s signed-in app.
    func `as`(_ did: String?) -> any HTTPTransport { Caller(pds: self, did: did) }

    /// What nobody signed in sees.
    var signedOut: any HTTPTransport { Caller(pds: self, did: nil) }

    private struct Caller: HTTPTransport {
        let pds: FakePDS
        let did: String?
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            var request = request
            request.setValue(did ?? "", forHTTPHeaderField: "X-Fake-Account")
            return try await pds.send(request)
        }
    }

    /// An identity resolver that finds every account here.
    var resolver: IdentityResolver {
        IdentityResolver(
            environment: ["ATDRIVE_PLC_URL": "https://plc.test", "ATDRIVE_HANDLE_RESOLVER": "https://pds.test"],
            transport: self)
    }

    /// `did`'s app: a client signed in as it.
    func client(as did: String = FakePDS.defaultDID) -> XRPCClient {
        XRPCClient(service: URL(string: "https://pds.test")!, transport: self.as(did))
    }

    /// How `did` (or nobody) reads other accounts' spaces.
    func access(as did: String? = FakePDS.defaultDID) -> SpaceAccess {
        SpaceAccess(ownClient: did.map { client(as: $0) }, resolver: resolver, transport: self.as(did))
    }

    // MARK: Handling requests

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onRequest?(request.url!.lastPathComponent)
        let latency = lock.withLock {
            atOnce += 1
            mostAtOnce = max(mostAtOnce, atOnce)
            return self.latency
        }
        defer { lock.withLock { atOnce -= 1 } }
        if let latency { try await Task.sleep(for: latency) }
        return lock.withLock { handle(request) }
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        // Identity: DID documents and handles.
        if url.host == "plc.test" {
            let did = url.lastPathComponent
            guard let account = accounts[did] else { return error(404, "NotFound") }
            return json([
                "id": did, "alsoKnownAs": ["at://\(account.handle)"],
                "service": [
                    ["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.test"]
                ],
                "verificationMethod": [
                    [
                        "id": "\(did)#atproto_kem", "type": "Multikey", "controller": did,
                        "publicKeyMultibase": P256DIDKey.multikey(account.kem.publicKey),
                    ]
                ],
            ])
        }
        if url.path == "/.well-known/atproto-did" {
            guard let did = accounts.first(where: { $0.value.handle == url.host })?.key else {
                return error(404, "NotFound")
            }
            return (Data(did.utf8), response(200))
        }

        let method = url.lastPathComponent
        calls.append(method)
        if let remaining = failing[method], remaining > 0 {
            failing[method] = remaining - 1
            return error(500, "InternalServerError")
        }
        if let remaining = failingAfter[method] {
            if remaining == 0 { return error(500, "InternalServerError") }
            failingAfter[method] = remaining - 1
        }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            },
            uniquingKeysWith: { a, _ in a })
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let headers = request.allHTTPHeaderFields ?? [:]
        let caller: String? = {
            guard let tagged = headers.first(where: { $0.key.lowercased() == "x-fake-account" })?.value else {
                return Self.defaultDID
            }
            return tagged.isEmpty ? nil : tagged
        }()
        // Space parameters in the PDS's form only, as the real one takes them since Nov 2026; kept
        // here in ATDrive's (`XRPCClient.local`), so tests name spaces as ATDrive does.
        let given = (body["space"] as? String) ?? query["space"]
        if let given, !given.hasPrefix(XRPCClient.wirePrefix) || XRPCClient.spaceParts(given) == nil {
            return error(400, "InvalidRequest", "Invalid \(method) params: Invalid space-ref (got \"\(given)\")")
        }
        let space = given.map(XRPCClient.local) ?? Self.space
        let repo = (body["repo"] as? String) ?? query["repo"] ?? caller ?? Self.defaultDID

        switch method {
        case "com.atproto.space.createSpace":
            guard let caller else { return error(401, "AuthRequired") }
            let uri = XRPCClient.spaceURI(
                authority: caller, type: body["spaceType"] as! String, key: body["skey"] as? String ?? TID.next())
            if let existing = spaces[uri], !existing.deleted { return error(400, "SpaceAlreadyExists") }
            spaces[uri] = SpaceState(authority: caller, policy: policy(body["policy"]))
            return json(["space": XRPCClient.wire(uri)])

        case "com.atproto.space.deleteSpace":
            guard let state = spaces[space], state.authority == caller else { return error(400, "SpaceNotFound") }
            if state.deleted { return json([:]) }
            spaces[space]?.deleted = true
            spaces[space]?.members = [:]
            for key in repos.keys where key.space == space { repos[key] = nil }
            credentials = credentials.filter { $0.value.space != space }
            collectGarbage()
            return json([:])

        case "com.atproto.space.updateSpace":
            guard let state = spaces[space], !state.deleted, state.authority == caller else {
                return error(400, "SpaceNotFound")
            }
            let new = policy(body["policy"])
            if Self.type(of: new) != Self.type(of: state.policy) { spaces[space]?.members = [:] }
            spaces[space]?.policy = new
            revokeCredentials(in: space)
            return json([:])

        case "com.atproto.space.getSpace":
            guard let state = spaces[space], !state.deleted, state.authority == caller else {
                return error(400, "SpaceNotFound")
            }
            return json([
                "space": XRPCClient.wire(space),
                "policy": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(state.policy)),
            ])

        case "com.atproto.space.listSpaces":
            guard let caller else { return error(401, "AuthRequired") }
            let owned = spaces.filter { !$0.value.deleted && $0.value.authority == caller }.map(\.key)
            let written = repos.keys.filter { $0.did == caller }.map(\.space)
            let all = Set(owned + written).sorted().filter { uri in
                query["spaceType"].map { XRPCClient.spaceParts(uri)?.type == $0 } ?? true
            }
            return json([
                "spaces": all.map { uri -> [String: Any] in
                    var view: [String: Any] = ["space": XRPCClient.wire(uri)]
                    if let rev = repos[RepoKey(space: uri, did: caller)]?.rev { view["repoRev"] = rev }
                    return view
                }
            ])

        case "com.atproto.space.listWriters":
            guard let state = spaces[space], !state.deleted else { return error(400, "SpaceNotFound") }
            if let authorization = headers.first(where: { $0.key.lowercased() == "authorization" })?.value,
                authorization.hasPrefix("Atproto-Space-Credential ")
            {
                let token = String(authorization.dropFirst("Atproto-Space-Credential ".count))
                guard let credential = credentials[token], credential.space == space else {
                    return error(401, "CredentialRevoked")
                }
                guard credential.expires > Date() else { return error(401, "ExpiredCredential") }
                guard SpaceRequestSigner.verify(headers, key: credential.key) else {
                    return error(401, "InvalidCredential")
                }
                guard canRead(credential.reader, state) else { return error(401, "CredentialRevoked") }
            } else if caller != state.authority {
                return error(400, "SpaceNotFound")
            }
            let writers = repos.filter { $0.key.space == space && $0.value.rev != nil && tracks($0.key.did, state) }
                .sorted { $0.value.rev! < $1.value.rev! }
            return json([
                "repos": writers.map { key, repo -> [String: Any] in
                    [
                        "$type": "com.atproto.space.defs#repoWrite", "repo": key.did, "repoRev": repo.rev!,
                        "spaceRev": repo.rev!,
                        "data": [
                            "$bytes": commitData(key).base64EncodedString().replacingOccurrences(of: "=", with: "")
                        ],
                    ]
                }
            ])

        case "com.atproto.memberspace.putMembers", "com.atproto.memberspace.removeMembers",
            "com.atproto.memberspace.listMembers":
            guard let state = spaces[space], !state.deleted, state.authority == caller else {
                return error(400, "SpaceNotFound")
            }
            guard case .members = state.policy else { return error(400, "PolicyMismatch") }
            switch method {
            case "com.atproto.memberspace.putMembers":
                for entry in body["members"] as! [[String: Any]] {
                    let member = SpaceMember(
                        did: entry["did"] as! String, read: entry["read"] as! Bool, write: entry["write"] as! Bool)
                    spaces[space]?.members[member.did] = member
                }
                return json([:])
            case "com.atproto.memberspace.removeMembers":
                for did in body["dids"] as! [String] {
                    spaces[space]?.members[did] = nil
                    credentials = credentials.filter { !($0.value.space == space && $0.value.reader == did) }
                }
                return json([:])
            default:
                return json([
                    "members": state.members.values.sorted { $0.did < $1.did }.map {
                        ["did": $0.did, "read": $0.read, "write": $0.write]
                    }
                ])
            }

        case "com.atproto.space.getDelegationToken":
            guard let caller else { return error(401, "AuthRequired") }
            let token = "delegation-\(UUID().uuidString)"
            delegationTokens[token] = (caller, space)
            return json(["token": token])

        case "com.atproto.space.authorizeSpaceSync":
            guard let state = spaces[space] else { return error(400, "SpaceNotFound") }
            if state.deleted { return error(400, "SpaceDeleted") }
            var reader: String?
            if let token = body["delegationToken"] as? String {
                guard let delegation = delegationTokens.removeValue(forKey: token), delegation.space == space else {
                    return error(400, "InvalidDelegationToken")
                }
                reader = delegation.did
            }
            guard canRead(reader, state) else { return error(400, "SpaceNotFound") }
            if refusingApps.contains(space) { return error(400, "AppNotAuthorized") }
            guard let keyText = body["credentialKey"] as? String, let key = P256DIDKey.publicKey(keyText) else {
                return error(400, "InvalidRequest")
            }
            let expires = Date().addingTimeInterval(credentialLifetime)
            let payload = Base64URL.encode(
                try! JSONSerialization.data(withJSONObject: [
                    "iss": state.authority, "sub": XRPCClient.wire(space), "exp": expires.timeIntervalSince1970,
                ]))
            let credential = "eyJ0eXAiOiJhdHByb3RvLXNwYWNlLWNyZWRlbnRpYWwrand0In0.\(payload).\(UUID().uuidString)"
            credentials[credential] = Credential(
                space: space, reader: reader,
                key: try! P256.Signing.PublicKey(compressedRepresentation: key.compressedRepresentation),
                expires: expires)
            return json(["credential": credential])

        case "com.atproto.repo.uploadBlob":
            let data = request.httpBody ?? Data()
            let cid = CID.forBlob(data)
            if blobs[cid] == nil || unreferencedSince[cid] != nil { unreferencedSince[cid] = commitCount }
            blobs[cid] = data
            return json([
                "blob": [
                    "$type": "blob", "ref": ["$link": cid], "mimeType": "application/octet-stream", "size": data.count,
                ]
            ])

        case "com.atproto.repo.getRecord":
            let key = "\(query["collection"] ?? "")/\(query["rkey"] ?? "")"
            guard let stored = publicRecords[query["repo"] ?? ""]?[key] else { return error(400, "RecordNotFound") }
            return json(["uri": "at://\(query["repo"]!)/\(key)", "cid": stored.cid, "value": parse(stored.json)])

        case "com.atproto.repo.putRecord":
            guard let caller, body["repo"] as? String == caller else { return error(401, "AuthRequired") }
            let key = "\(body["collection"] as! String)/\(body["rkey"] as! String)"
            let json = try! JSONSerialization.data(withJSONObject: body["record"]!, options: [.sortedKeys])
            let cid = "bafyrecord" + CID.forBlob(json).dropFirst(7)
            publicRecords[caller, default: [:]][key] = Stored(cid: cid, json: json, blobs: [])
            return self.json(["uri": "at://\(caller)/\(key)", "cid": cid])

        case "com.atproto.repo.deleteRecord":
            guard let caller, body["repo"] as? String == caller else { return error(401, "AuthRequired") }
            publicRecords[caller]?["\(body["collection"] as! String)/\(body["rkey"] as! String)"] = nil
            return json([:])

        case "com.atproto.lexicon.resolveLexicon":
            guard let nsid = query["nsid"], let schema = lexicons[nsid] else { return error(400, "LexiconNotFound") }
            return json([
                "uri": "at://did:plc:lexicons/com.atproto.lexicon.schema/\(nsid)", "cid": "bafylexicon",
                "schema": schema,
            ])

        case "com.atproto.identity.resolveHandle":
            guard let did = accounts.first(where: { $0.value.handle == query["handle"] })?.key else {
                return error(400, "HandleNotFound")
            }
            return json(["did": did])

        case "com.atproto.space.putRecord", "com.atproto.space.createRecord", "com.atproto.space.applyWrites",
            "com.atproto.space.clearRecords":
            guard let caller, caller == repo else { return error(401, "AuthRequired") }
            guard let state = spaces[space], !state.deleted else { return error(400, "SpaceNotFound") }
            guard tracks(caller, state) else { return error(400, "NotAuthorized") }
            return write(method, body: body, request: request, key: RepoKey(space: space, did: repo))

        case "com.atproto.space.listRecords", "com.atproto.space.getBlob", "com.atproto.space.getLatestCommit",
            "com.atproto.space.listRepoOps":
            let key = RepoKey(space: space, did: repo)
            if let authorization = headers.first(where: { $0.key.lowercased() == "authorization" })?.value,
                authorization.hasPrefix("Atproto-Space-Credential ")
            {
                let token = String(authorization.dropFirst("Atproto-Space-Credential ".count))
                guard let credential = credentials[token], credential.space == space else {
                    return error(401, "CredentialRevoked")
                }
                guard credential.expires > Date() else { return error(401, "ExpiredCredential") }
                guard SpaceRequestSigner.verify(headers, key: credential.key),
                    headers.first(where: { $0.key.lowercased() == "atproto-space-audience" })?.value == repo
                else { return error(401, "InvalidCredential") }
                guard let state = spaces[space], !state.deleted, canRead(credential.reader, state) else {
                    return error(401, "CredentialRevoked")
                }
                if method == "com.atproto.space.getBlob", let cid = query["cid"],
                    !(repos[key]?.records.values.contains { $0.blobs.contains(cid) } ?? false)
                {
                    return error(400, "BlobNotFound")
                }
                if SpaceCredentials.committing.contains(method),
                    headers.first(where: { $0.key.lowercased() == "accept-signature" }) == nil
                {
                    return error(400, "InvalidSpaceMac")
                }
            } else if let caller, caller != repo {
                return error(400, "SpaceNotFound")
            } else if caller == nil {
                return error(401, "AuthRequired")
            }
            return read(method, query: query, headers: headers, key: key)

        default:
            return error(501, "MethodNotImplemented")
        }
    }

    private func canRead(_ reader: String?, _ state: SpaceState) -> Bool {
        if reader == state.authority { return true }
        guard case .members(let publicRead, _) = state.policy else { return false }
        return publicRead || reader.flatMap { state.members[$0]?.read } == true
    }

    /// Whether the space tracks `writer`'s writes (lists it in `listWriters`): its authority,
    /// members with write access, and with `publicWrite` anyone but members without it. (The
    /// protocol lets anyone write their own repo in any space, and only stops tracking it; here
    /// an untracked write is refused, so a test notices one.)
    private func tracks(_ writer: String, _ state: SpaceState) -> Bool {
        if writer == state.authority { return true }
        if let member = state.members[writer] { return member.write }
        if case .members(_, true) = state.policy { return true }
        return false
    }

    private func revokeCredentials(in space: String) {
        guard let state = spaces[space] else { return }
        credentials = credentials.filter { $0.value.space != space || canRead($0.value.reader, state) }
    }

    private func policy(_ value: Any?) -> SpacePolicy {
        let data = try! JSONSerialization.data(withJSONObject: value ?? [:])
        return (try? JSONDecoder().decode(SpacePolicy.self, from: data)) ?? .personal
    }

    private static func type(of policy: SpacePolicy) -> String {
        switch policy {
        case .personal: "personal"
        case .members: "members"
        case .other(let type): type
        }
    }

    private func write(_ method: String, body: [String: Any], request: URLRequest, key: RepoKey) -> (
        Data, HTTPURLResponse
    ) {
        let records = repos[key]?.records ?? [:]
        switch method {
        case "com.atproto.space.putRecord":
            let collection = body["collection"] as? String ?? Lexicon.node
            let rkey = body["rkey"] as! String
            if referencesMissingBlob(body["record"]!) { return error(400, "BlobNotFound") }
            let cid = commit([(collection, rkey, body["record"]!)], to: key)
            return json(["uri": "at://\(key.did)/\(collection)/\(rkey)", "cid": cid.first!])

        case "com.atproto.space.createRecord":
            let collection = body["collection"] as! String
            let rkey = body["rkey"] as? String ?? TID.next()
            if records["\(collection)/\(rkey)"] != nil { return error(400, "RecordAlreadyExists") }
            if referencesMissingBlob(body["record"]!) { return error(400, "BlobNotFound") }
            let cid = commit([(collection, rkey, body["record"]!)], to: key)
            return json(["uri": "at://\(key.did)/\(collection)/\(rkey)", "cid": cid.first!])

        case "com.atproto.space.clearRecords":
            clear(key)
            return json([:])

        default:  // applyWrites
            let size = request.httpBody?.count ?? 0
            if let limit = requestLimit, size > limit { return error(413, "PayloadTooLarge") }
            biggestTransaction = max(biggestTransaction, size)
            // One transaction: checked in full before anything is written.
            var writes: [(collection: String, rkey: String, value: Any?)] = []
            var types: [String] = []
            var exists = Set(records.keys)
            let requested = body["writes"] as! [[String: Any]]
            guard requested.count <= 200 else { return error(400, "InvalidRequest") }
            // A record can't reference a blob the PDS doesn't have (any more).
            for write in requested {
                if let value = write["value"], referencesMissingBlob(value) { return error(400, "BlobNotFound") }
            }
            for write in requested {
                let collection = write["collection"] as! String
                let rkey = write["rkey"] as? String ?? TID.next()
                let recordKey = "\(collection)/\(rkey)"
                switch write["$type"] as? String {
                case "com.atproto.space.applyWrites#delete":
                    guard exists.remove(recordKey) != nil else { return error(400, "RecordNotFound") }
                    writes.append((collection, rkey, nil))
                    types.append("deleteResult")
                case "com.atproto.space.applyWrites#create":
                    guard exists.insert(recordKey).inserted else { return error(400, "RecordAlreadyExists") }
                    writes.append((collection, rkey, write["value"]!))
                    types.append("createResult")
                case "com.atproto.space.applyWrites#update":
                    guard exists.contains(recordKey) else { return error(400, "RecordNotFound") }
                    writes.append((collection, rkey, write["value"]!))
                    types.append("updateResult")
                default:
                    return error(400, "InvalidRequest")
                }
            }
            let cids = commit(writes, to: key)
            return json([
                "results": zip(zip(writes, types), cids).map { pair, cid -> [String: Any] in
                    let ((collection, rkey, _), type) = pair
                    var result: [String: Any] = ["$type": "com.atproto.space.applyWrites#\(type)"]
                    if let cid {
                        result["uri"] = "at://\(key.did)/\(collection)/\(rkey)"
                        result["cid"] = cid
                    }
                    return result
                }
            ])
        }
    }

    private func read(_ method: String, query: [String: String], headers: [String: String], key: RepoKey)
        -> (Data, HTTPURLResponse)
    {
        let repo = repos[key] ?? Repo()
        switch method {
        case "com.atproto.space.listRecords":
            guard spaces[key.space].map({ !$0.deleted }) ?? false else { return error(400, "SpaceNotFound") }
            let cursor = query["cursor"]
            let collection = query["collection"]
            let keys = repo.records.keys.sorted().filter { key in
                (collection.map { key.hasPrefix($0 + "/") } ?? true) && (cursor.map { key > $0 } ?? true)
            }
            let page = Array(keys.prefix(pageSize))
            var output: [String: Any] = [
                "records": page.map { recordKey in
                    let (collection, rkey) = split(recordKey)
                    return [
                        "collection": collection, "rkey": rkey, "cid": repo.records[recordKey]!.cid,
                        "value": parse(repo.records[recordKey]!.json),
                    ]
                }
            ]
            if keys.count > page.count { output["cursor"] = page.last! }
            return json(output)

        case "com.atproto.space.getBlob":
            guard var data = blobs[query["cid"] ?? ""] else { return error(400, "BlobNotFound") }
            if corruptDownloads, !data.isEmpty { data[data.startIndex] ^= 0xFF }
            return (data, response(200))

        case "com.atproto.space.getLatestCommit":
            guard let rev = repo.rev else { return error(400, "RepoNotFound") }
            let commit = commitJSON(rev, key: key)
            return json(["commit": commit], headers: macHeaders(commit, key: key, request: headers))

        default:  // listRepoOps
            // As the reference PDS (2026-11-12): a repo never written to is `RepoNotFound`.
            guard let rev = repo.rev else { return error(400, "RepoNotFound") }
            var position: (rev: String, idx: Int)?
            if let cursor = query["cursor"] {
                let parts = cursor.split(separator: "/")
                position = (String(parts[0]), Int(parts[1])!)
            } else if let since = query["since"] {
                position = (since, Int.max)
            }
            let limit = min(Int(query["limit"] ?? "100")!, 1000, opsPageSize)
            let after = repo.oplog.filter { op in
                guard let position else { return true }
                return op.rev > position.rev || (op.rev == position.rev && op.idx > position.idx)
            }
            let page = after.prefix(limit)
            var output: [String: Any] = [
                "ops": page.map { op -> [String: Any] in
                    var entry: [String: Any] = [
                        "rev": op.rev, "collection": op.collection, "rkey": op.rkey,
                        "cid": op.cid.map { $0 as Any } ?? NSNull(), "prev": op.prev.map { $0 as Any } ?? NSNull(),
                    ]
                    // Only the record's current value: a version a later op replaced has none.
                    if let cid = op.cid, let stored = repo.records["\(op.collection)/\(op.rkey)"], stored.cid == cid {
                        entry["value"] = parse(stored.json)
                    }
                    return entry
                }
            ]
            // Like the reference (2026-11-12): every page carries the current commit, and a full
            // page has a cursor, even at the head (so the last page may be empty).
            if page.count == limit, let last = page.last { output["cursor"] = "\(last.rev)/\(last.idx)" }
            let commit = commitJSON(rev, key: key)
            output["commit"] = commit
            return json(output, headers: macHeaders(commit, key: key, request: headers))
        }
    }

    /// The MAC headers answering a request's `Accept-Signature`, if it has one.
    private func macHeaders(_ commit: [String: Any], key: RepoKey, request: [String: String]) -> [String: String] {
        guard let accept = request.first(where: { $0.key.lowercased() == "accept-signature" })?.value,
            let account = accounts[key.did],
            let decoded = try? JSONDecoder().decode(
                RepoCommit.self, from: JSONSerialization.data(withJSONObject: commit))
        else { return [:] }
        let kem = forgeMACs ? P256.KeyAgreement.PrivateKey() : account.kem
        return (try? SpaceMAC.responseHeaders(for: decoded, acceptSignature: accept, kemKey: kem)) ?? [:]
    }

    /// Writes records (`nil` deletes) as one commit, logging an op for each. Returns their CIDs.
    @discardableResult
    private func commit(_ writes: [(collection: String, rkey: String, value: Any?)], to key: RepoKey) -> [String?] {
        let newRev = TID.next()
        var repo = repos[key] ?? Repo()
        var cids: [String?] = []
        for (index, write) in writes.enumerated() {
            let recordKey = "\(write.collection)/\(write.rkey)"
            let prev = repo.records[recordKey]?.cid
            var cid: String?
            if let value = write.value {
                // Content-addressed, like real record CIDs: the same record has the same CID.
                let json = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                cid = "bafyrecord" + CID.forBlob(json).dropFirst(7)
                repo.records[recordKey] = Stored(cid: cid!, json: json, blobs: Self.blobReferences(in: value))
            } else {
                repo.records[recordKey] = nil
            }
            repo.oplog.append(
                Op(rev: newRev, idx: index, collection: write.collection, rkey: write.rkey, cid: cid, prev: prev))
            cids.append(cid)
        }
        repo.rev = newRev
        repos[key] = repo
        commitCount += 1
        collectGarbage()
        return cids
    }

    /// The CIDs of the blobs a record value references (`{"$type": "blob", "ref": {"$link": …}}`).
    private static func blobReferences(in value: Any) -> Set<String> {
        var found: Set<String> = []
        var stack = [value]
        while let next = stack.popLast() {
            if let object = next as? [String: Any] {
                if object["$type"] as? String == "blob",
                    let link = (object["ref"] as? [String: Any])?["$link"] as? String
                {
                    found.insert(link)
                } else {
                    stack += object.values
                }
            } else if let array = next as? [Any] {
                stack += array
            }
        }
        return found
    }

    /// Deletes blobs nothing references: at once if something did, else after `blobGrace`
    /// commits.
    private func collectGarbage() {
        var referenced: Set<String> = []
        for repo in repos.values {
            for stored in repo.records.values { referenced.formUnion(stored.blobs) }
        }
        for cid in Array(blobs.keys) where !referenced.contains(cid) {
            if let since = unreferencedSince[cid], commitCount - since <= blobGrace { continue }
            blobs[cid] = nil
            unreferencedSince[cid] = nil
            collectedBlobs.insert(cid)
        }
        for cid in referenced { unreferencedSince[cid] = nil }
    }

    /// Whether a blob is stored (it may have been garbage-collected).
    func hasBlob(_ cid: String) -> Bool { lock.withLock { blobs[cid] != nil } }

    /// Whether a record value references a blob that isn't stored.
    private func referencesMissingBlob(_ value: Any) -> Bool {
        Self.blobReferences(in: value).contains { blobs[$0] == nil }
    }

    /// Every record's key in a collection of a repo (the default drive's, unless told).
    func keys(in collection: String, space: String = FakePDS.space, did: String? = nil) -> [String] {
        lock.withLock {
            (repos[RepoKey(space: space, did: did ?? owner(of: space))]?.records ?? [:]).keys
                .filter { $0.hasPrefix(collection + "/") }.map { split($0).rkey }.sorted()
        }
    }

    /// A space's authority (who writes its records, for now).
    private func owner(of space: String) -> String { XRPCClient.spaceParts(space)?.authority ?? Self.defaultDID }

    private func commitJSON(_ rev: String, key: RepoKey) -> [String: Any] {
        var data = commitData(key)
        if lyingCommits > 0 {
            lyingCommits -= 1
            data[0] ^= 0xFF
        }
        return [
            "ver": 1, "repo": key.did, "space": XRPCClient.wire(key.space),
            // Unpadded base64, as atproto writes it.
            "rev": rev, "data": ["$bytes": data.base64EncodedString().replacingOccurrences(of: "=", with: "")],
        ]
    }

    /// The LtHash over every current record, as the reference's commit holds. Computed from
    /// scratch each time, whatever wrote the records; the repos here are small.
    private func commitData(_ key: RepoKey) -> Data {
        var hash = RepoSetHash()
        for (recordKey, stored) in repos[key]?.records ?? [:] {
            let (collection, rkey) = split(recordKey)
            hash.add(collection: collection, rkey: rkey, cid: stored.cid)
        }
        return hash.setHash.digest
    }

    /// The `data` an honest commit of the default drive would have now.
    var currentCommitData: Data { lock.withLock { commitData(Self.defaultKey) } }

    private func split(_ key: String) -> (collection: String, rkey: String) {
        let slash = key.lastIndex(of: "/")!
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    private func parse(_ json: Data) -> Any { try! JSONSerialization.jsonObject(with: json) }

    /// Stores a record exactly as given, bypassing `Drive`, to set up odd states. It goes
    /// through the change feed like any write. Creates the space if it doesn't exist.
    func insertRawRecord(
        rkey: String, collection: String = Lexicon.node, space: String = FakePDS.space, did: String? = nil,
        _ record: [String: Any]
    ) {
        lock.withLock {
            let did = did ?? owner(of: space)
            if spaces[space].map({ $0.deleted }) ?? true {
                spaces[space] = SpaceState(authority: owner(of: space), policy: .personal)
            }
            commit([(collection, rkey, record)], to: RepoKey(space: space, did: did))
        }
    }

    /// Deletes a record, bypassing `Drive`.
    func deleteRawRecord(rkey: String, collection: String = Lexicon.node, space: String = FakePDS.space) {
        lock.withLock { _ = commit([(collection, rkey, nil)], to: RepoKey(space: space, did: owner(of: space))) }
    }

    /// The record's CID, if it exists.
    func cid(of rkey: String, collection: String = Lexicon.node, space: String = FakePDS.space) -> String? {
        lock.withLock { repos[RepoKey(space: space, did: owner(of: space))]?.records["\(collection)/\(rkey)"]?.cid }
    }

    /// Drops the default drive's change feed ops up to and including `rev`, as a server may.
    func compactOps(through rev: String) {
        lock.withLock { repos[Self.defaultKey]?.oplog.removeAll { $0.rev <= rev } }
    }

    /// Like `com.atproto.space.clearRecords`: deletes every record of the default drive and its
    /// whole change feed, leaving the repo at a new revision.
    func clearRecords() {
        lock.withLock { clear(Self.defaultKey) }
    }

    private func clear(_ key: RepoKey) {
        repos[key] = Repo(records: [:], oplog: [], rev: TID.next())
        collectGarbage()
    }

    /// Deletes the default drive's space, as a wiped server would have: records, change feed,
    /// repo and blobs.
    func wipe() {
        lock.withLock {
            spaces[Self.space] = nil
            repos[Self.defaultKey] = nil
            blobs = [:]
            unreferencedSince = [:]
        }
    }

    /// Whether a space exists (and isn't deleted).
    func exists(_ space: String) -> Bool { lock.withLock { spaces[space].map { !$0.deleted } ?? false } }

    /// A space's policy and members, as its host keeps them.
    func policy(of space: String) -> (policy: SpacePolicy, members: [String])? {
        lock.withLock { spaces[space].map { ($0.policy, $0.members.keys.sorted()) } }
    }

    /// A record in an account's public repo.
    func publicRecord(_ did: String, collection: String, rkey: String) -> [String: Any]? {
        lock.withLock { publicRecords[did]?["\(collection)/\(rkey)"].map { parse($0.json) } as? [String: Any] }
    }

    /// Every space that exists, and isn't deleted.
    var allSpaces: [String] { lock.withLock { spaces.filter { !$0.value.deleted }.keys.sorted() } }

    private func json(_ object: Any, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), response(200, headers: headers))
    }

    private func error(_ status: Int, _ name: String, _ message: String? = nil) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: ["error": name, "message": message ?? name]), response(status))
    }

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://pds.test")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}

/// Replays canned responses in order and records the requests it was sent.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String, [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String, [String: String])]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            requests.append(request)
            let (status, body, headers) = responses.removeFirst()
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            )
        }
    }
}

extension FakePDS {
    /// A device using this PDS's drive (`did:plc:test`), with tiny chunks (8 bytes, unless
    /// `transfers` says otherwise). Pass `keyring` to give it an encrypted drive's keys straight
    /// away (devices sharing one, as tests do), or `mode` to say what the drive is without
    /// opening it; or create the drive with it (`Drive.create`), or open it.
    ///
    /// With neither, it takes the drive to be `TestMode.current`: the drive-logic suites run
    /// once on a plain drive and once on an encrypted one (`scripts/test.sh`).
    func device(
        _ name: String = "test", account: String = FakePDS.defaultDID, transfers: TransferOptions = .fixed(8),
        tids: TIDSource = .system, keyring: Keyring? = nil, mode: DriveMode? = nil, identity: DeviceIdentity? = nil,
        saveIdentity: (@Sendable (DeviceIdentity) -> Void)? = nil
    ) -> Drive {
        Drive(
            client: client(as: account), owner: account,
            transfers: transfers, device: name, tids: tids, identity: identity ?? DeviceIdentity(name: name),
            mode: mode ?? (keyring == nil && TestMode.current == .plain ? .plain : nil), keyring: keyring,
            saveIdentity: saveIdentity)
    }

    /// A device that doesn't know yet whether the drive is encrypted: it has to open it.
    func unopened(
        _ name: String = "test", account: String = FakePDS.defaultDID, transfers: TransferOptions = .fixed(8),
        identity: DeviceIdentity? = nil
    ) -> Drive {
        Drive(
            client: client(as: account), owner: account,
            transfers: transfers, device: name, identity: identity ?? DeviceIdentity(name: name))
    }

    /// The space every test drive is.
    static let space = XRPCClient.spaceURI(
        authority: "did:plc:test", type: Lexicon.driveSpace, key: Lexicon.defaultDriveKey)

    /// A record's value as stored, if it exists.
    func rawRecord(rkey: String, collection: String = Lexicon.node, space: String = FakePDS.space) -> [String: Any]? {
        lock.withLock {
            repos[RepoKey(space: space, did: owner(of: space))]?.records["\(collection)/\(rkey)"]
                .flatMap { try? JSONSerialization.jsonObject(with: $0.json) } as? [String: Any]
        }
    }

    /// Every record and blob as stored: all the PDS has.
    var everythingStored: [Data] {
        lock.withLock {
            repos.values.flatMap { $0.records.values.map(\.json) }
                + publicRecords.values.flatMap { $0.values.map(\.json) }
                + Array(blobs.values)
        }
    }

    /// Stores `payload` (any JSON object) as a record the way `drive` stores records now: sealed
    /// with its keyring, or plain.
    func insert(rkey: String, collection: String = Lexicon.node, _ payload: [String: Any], as drive: Drive) throws {
        if let keyring = drive.keyring {
            try insertSealed(rkey: rkey, collection: collection, payload, keyring: keyring)
        } else {
            insertRawRecord(rkey: rkey, collection: collection, payload.merging(["$type": collection]) { a, _ in a })
        }
    }

    /// Seals `payload` (any JSON object) with `keyring` for `collection`/`rkey` and stores it, as
    /// a device with that keyring (a newer version of ATDrive, or another drive) would.
    func insertSealed(
        rkey: String, collection: String = Lexicon.node, _ payload: [String: Any], keyring: Keyring,
        chunks: [[String: Any]]? = nil
    ) throws {
        let value = try JSONValue(parsing: JSONSerialization.data(withJSONObject: payload))
        let sealed = try keyring.seal(value, space: Self.space, collection: collection, rkey: rkey)
        var record: [String: Any] = [
            "$type": collection,
            "sealed": ["keyID": sealed.keyID.rawValue, "sealed": ["$bytes": Base64.encode(sealed.sealed.data)]],
        ]
        if let chunks { record["chunks"] = chunks }
        insertRawRecord(rkey: rkey, collection: collection, record)
    }
}

extension TransferOptions {
    /// Chunks of exactly `size` bytes (a power of two, 8 or more), the last one shorter: small
    /// files get several chunks, at places a test can count on.
    static func fixed(_ size: Int, parallel: Int = 4) -> TransferOptions {
        TransferOptions(chunking: .init(minSize: size, averageSize: size, maxSize: size), parallel: parallel)
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("atdrive-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Which kind of drive the drive-logic suites run on: `ATDRIVE_TEST_MODE=encrypted` for an
/// encrypted one, a plain one otherwise. Everything but how records are stored should behave the
/// same, so the same tests run on both.
enum TestMode {
    static let current: DriveMode =
        ProcessInfo.processInfo.environment["ATDRIVE_TEST_MODE"] == "encrypted" ? .encrypted : .plain
    static var encrypted: Bool { current == .encrypted }

    /// A keyring for devices that share one, on an encrypted drive; none on a plain one.
    static func keyring() -> Keyring? { encrypted ? Keyring(DriveKey()) : nil }
}

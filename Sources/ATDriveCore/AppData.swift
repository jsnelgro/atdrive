import Crypto
import Foundation

// The apps view (#28): everything in the spaces the account is in, not just ATDrive's files.
// Other atproto apps keep data in spaces too (a Bulletin board's notes, say), and people share
// spaces with you. This reads them all, read-only: ATDrive writes with `validate = false`, so
// letting edits through could quietly corrupt another app's data.
//
// Where it comes from:
// 1. `listSpaces` on the account's own PDS: the spaces it owns or has written to, with its repo's
//    revision in each. Its own repos are read with its session.
// 2. Everyone else's repos in those spaces: a credential from the space's host (as for shares,
//    `SpaceCredentials`), `listWriters` there, then each writer's repo at their own PDS.
// 3. Spaces shared with the account that it never wrote to, which `listSpaces` doesn't list:
//    added by address, and remembered in the home drive (`AddedSpace`) for every device.
//
// ATDrive's own drive spaces aren't shown: they're the drive. A space that won't let ATDrive in
// (`allowedApps`, say) is shown with why, not hidden.

/// A space from another app, added to the apps view by address: `me.jsnelgro.atdrive.addedSpace`
/// in the home drive, sealed on an encrypted drive.
public struct AddedSpace: Codable, Sendable, Equatable {
    public var space: String
    public var addedAt: String

    public init(space: String, addedAt: Date = Date()) {
        self.space = space
        self.addedAt = Timestamp.format(addedAt)
    }

    /// Its record key: the first 16 bytes of the SHA-256 of the space's URI, in base32. The same
    /// space always has the same key, so adding it twice (on two devices, say) is one record.
    public static func key(for space: String) -> String {
        Base32.encode(Array(SHA256.hash(data: Data(space.utf8))).prefix(16))
    }
}

/// A record in another app's space, as stored.
public struct AppRecord: Sendable, Equatable {
    public var collection: String
    public var rkey: String
    public var cid: String
    public var value: JSONValue

    public init(collection: String, rkey: String, cid: String, value: JSONValue) {
        self.collection = collection
        self.rkey = rkey
        self.cid = cid
        self.value = value
    }
}

/// One account's repo in a space, at a revision.
public struct AppRepo: Sendable, Equatable {
    public var did: String
    public var rev: String
    /// By `collection/rkey`.
    public var records: [String: AppRecord]

    public init(did: String, rev: String, records: [String: AppRecord]) {
        self.did = did
        self.rev = rev
        self.records = records
    }
}

/// Why some of a space isn't shown.
public enum AppSpaceProblem: Sendable, Equatable, CustomStringConvertible {
    /// Its host refused: not shared with this account (any more), deleted, or not letting
    /// ATDrive in. Other people's repos in it aren't shown.
    case access(SpaceAccessProblem)
    /// Couldn't be reached just now: what was there last time is still shown.
    case unreachable(String)

    public var description: String {
        switch self {
        case .access(.appNotAllowed): "its owner lets only certain apps read it, and ATDrive isn't one of them"
        case .access(let problem): problem.description
        case .unreachable(let detail): "it couldn't be reached just now (\(detail))"
        }
    }
}

/// A space the account is in, with every repo in it that could be read.
public struct AppSpace: Sendable, Equatable {
    public var uri: String
    public var authority: String
    public var type: String
    public var key: String
    /// Added by address (`AddedSpace`), rather than (only) listed by the account's PDS.
    public var added: Bool
    /// By DID.
    public var repos: [String: AppRepo]
    public var problem: AppSpaceProblem?

    public init(uri: String, added: Bool, repos: [String: AppRepo] = [:], problem: AppSpaceProblem? = nil) {
        let parts = XRPCClient.spaceParts(uri)
        self.uri = uri
        authority = parts?.authority ?? ""
        type = parts?.type ?? ""
        key = parts?.key ?? ""
        self.added = added
        self.repos = repos
        self.problem = problem
    }
}

/// Everything in the apps view at one moment. Give it to the next `AppData.update`, which reads
/// again only the repos whose revision moved.
public struct AppDataSnapshot: Sendable, Equatable {
    public var account: String
    /// By URI.
    public var spaces: [String: AppSpace]
    /// Handles of the accounts in it, by DID, where they resolved.
    public var handles: [String: String]

    public init(account: String, spaces: [String: AppSpace], handles: [String: String] = [:]) {
        self.account = account
        self.spaces = spaces
        self.handles = handles
    }

    /// As files and folders.
    public var tree: AppTree { AppTree(self) }
}

public enum AppDataError: Error, Equatable, CustomStringConvertible {
    case notASpace(String)
    /// ATDrive's own spaces are the drive (`atdrive open-share` for one shared with you).
    case driveSpace
    case notAdded(String)
    /// The apps view is off (`apps.enabled` in config.toml).
    case off
    /// The session wasn't granted what this needs: sign in again.
    case needsSignIn

    public var description: String {
        switch self {
        case .notASpace(let text):
            "\(text) isn't a space's address (at://<handle or DID>/space/<type>/<key>)"
        case .driveSpace:
            "that's an ATDrive space: open it with `atdrive open-share <link>` to put it in your drive"
        case .notAdded(let space): "\(space) wasn't added"
        case .off:
            "the apps view is off. Turn it on with `atdrive apps on` (apps.enabled in config.toml)"
        case .needsSignIn:
            "this sign-in doesn't allow that. Sign in again (`atdrive login <handle>`) to grant it"
        }
    }
}

/// Reads the apps view for the signed-in account: `update` gives an `AppDataSnapshot`, and
/// `contents` reads a file in its tree. Credentials and identities are kept between updates.
public actor AppData {
    public let client: XRPCClient
    public let account: String
    let access: SpaceAccess
    /// The home drive, which remembers spaces added by address; `nil` to leave those out.
    let home: Drive?
    private var credentials: [String: SpaceCredentials] = [:]
    private var identities: [String: ResolvedIdentity] = [:]
    private var unresolvable: Set<String> = []

    public init(home: Drive, access: SpaceAccess) {
        client = home.client
        account = home.owner
        self.access = access
        self.home = home
    }

    public init(client: XRPCClient, account: String, access: SpaceAccess) {
        self.client = client
        self.account = account
        self.access = access
        home = nil
    }

    /// Whether a space belongs in the apps view: not ATDrive's own (that's the drive).
    public static func isShown(_ space: String) -> Bool {
        guard let parts = XRPCClient.spaceParts(space) else { return false }
        return parts.type != Lexicon.driveSpace
    }

    // MARK: Reading

    /// The apps view now. Repos whose revision hasn't moved since `previous` are taken from it,
    /// and the rest follow their change feed from there (or are listed again in full). A space
    /// that can't be read is in it with its problem; one that can't be reached keeps what
    /// `previous` had. Throws only if the account's own PDS can't be read.
    public func update(_ previous: AppDataSnapshot? = nil) async throws -> AppDataSnapshot {
        let views: [SpaceView]
        do {
            views = try await client.listSpaceViews()
        } catch let error as XRPCError where Self.isScopeRefusal(error) {
            throw AppDataError.needsSignIn
        }
        var known: [String: (rev: String?, added: Bool)] = [:]
        for view in views where Self.isShown(view.space) { known[view.space] = (view.repoRev, false) }
        for space in try await addedSpaces() where Self.isShown(space) {
            known[space] = (known[space]?.rev, true)
        }
        var spaces: [String: AppSpace] = [:]
        await withTaskGroup(of: AppSpace.self) { group in
            for (uri, info) in known {
                let before = previous?.spaces[uri]
                group.addTask { await self.read(uri, ownRev: info.rev, added: info.added, previous: before) }
            }
            for await space in group { spaces[space.uri] = space }
        }
        var handles: [String: String] = [:]
        var dids: Set<String> = []
        for space in spaces.values {
            dids.insert(space.authority)
            dids.formUnion(space.repos.keys)
        }
        for did in dids {
            if let handle = await identity(of: did)?.handle { handles[did] = handle }
        }
        return AppDataSnapshot(account: account, spaces: spaces, handles: handles)
    }

    private func read(_ uri: String, ownRev: String?, added: Bool, previous: AppSpace?) async -> AppSpace {
        var space = AppSpace(uri: uri, added: added)
        if let ownRev {
            do {
                space.repos[account] = try await Self.readRepo(
                    client, space: uri, did: account, rev: ownRev, previous: previous?.repos[account])
            } catch {
                if let held = previous?.repos[account] { space.repos[account] = held }
                space.problem = SpaceAccessProblem(error).map { .access($0) } ?? .unreachable(Self.describe(error))
            }
        }
        // Everyone else's repos, through the space's host.
        do {
            let credentials = try await credentials(for: uri)
            for writer in try await credentials.client.listWriters(space: uri) where writer.did != account {
                do {
                    let reader = try await client(for: writer.did, credentials: credentials)
                    space.repos[writer.did] = try await Self.readRepo(
                        reader, space: uri, did: writer.did, rev: writer.rev, previous: previous?.repos[writer.did])
                } catch {
                    // That one repo can't be read now. Kept as it was, unless its host says it's
                    // gone (a suspended account, say).
                    if SpaceAccessProblem(error) == nil, let held = previous?.repos[writer.did] {
                        space.repos[writer.did] = held
                    }
                }
            }
        } catch {
            if let problem = SpaceAccessProblem(error) {
                // Not readable: losing access only removes a read-only copy, so others' repos go.
                self.credentials[uri] = nil
                space.problem = .access(problem)
            } else {
                for (did, repo) in previous?.repos ?? [:] where did != account { space.repos[did] = repo }
                space.problem = space.problem ?? .unreachable(Self.describe(error))
            }
        }
        return space
    }

    /// A repo at `rev`: `previous` if that's where it was, else followed from there by its change
    /// feed, else listed in full.
    static func readRepo(_ client: XRPCClient, space: String, did: String, rev: String, previous: AppRepo?)
        async throws -> AppRepo
    {
        if let previous {
            if previous.rev == rev { return previous }
            if let followed = try? await follow(client, space: space, did: did, from: previous) { return followed }
        }
        var records: [String: AppRecord] = [:]
        var cursor: String?
        repeat {
            let page = try await client.listRawSpaceRecords(space: space, repo: did, collection: nil, cursor: cursor)
            for record in page.records {
                guard let collection = record.collection else {
                    throw ATDriveError.unexpectedResponse(
                        "com.atproto.space.listRecords: a record without its collection")
                }
                records["\(collection)/\(record.rkey)"] = AppRecord(
                    collection: collection, rkey: record.rkey, cid: record.cid, value: record.value ?? .null)
            }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return AppRepo(did: did, rev: rev, records: records)
    }

    /// `previous` brought up to date with the change feed; `nil` if the feed has a gap (it was
    /// compacted, or `previous` was listed mid-write), so it has to be listed again.
    static func follow(_ client: XRPCClient, space: String, did: String, from previous: AppRepo) async throws
        -> AppRepo?
    {
        var records = previous.records
        // Written, but replaced by a later op not seen yet: a later op must give its value.
        var withoutValue: Set<String> = []
        var head = previous.rev
        var cursor: String?
        repeat {
            let page = try await client.listRepoOps(space: space, repo: did, since: previous.rev, cursor: cursor)
            for op in page.ops {
                let key = "\(op.collection)/\(op.rkey)"
                guard records[key]?.cid == op.prev else { return nil }
                if let cid = op.cid {
                    records[key] = AppRecord(
                        collection: op.collection, rkey: op.rkey, cid: cid, value: op.value ?? .null)
                    if op.value == nil { withoutValue.insert(key) } else { withoutValue.remove(key) }
                } else {
                    records[key] = nil
                    withoutValue.remove(key)
                }
            }
            if let rev = page.commit?.rev { head = rev }
            cursor = page.cursor
        } while cursor != nil
        guard withoutValue.isEmpty else { return nil }
        return AppRepo(did: did, rev: head, records: records)
    }

    /// What a file in the tree holds: a record as JSON, a note, or a blob (downloaded).
    public func contents(of item: AppTree.Item) async throws -> Data {
        switch item.content {
        case .folder: throw ATDriveError.isAFolder(item.name)
        case .record(let data): return data
        case .note(let text): return Data(text.utf8)
        case .blob(let space, let repo, let cid, _): return try await blob(space: space, repo: repo, cid: cid)
        }
    }

    /// A blob in a repo in a space: the account's own through its session, anyone else's through
    /// the space's host's credential, at their own PDS.
    public func blob(space: String, repo: String, cid: String) async throws -> Data {
        if repo == account { return try await client.getSpaceBlob(space: space, repo: repo, cid: cid) }
        let credentials = try await credentials(for: space)
        return try await client(for: repo, credentials: credentials).getSpaceBlob(space: space, repo: repo, cid: cid)
    }

    private func credentials(for space: String) async throws -> SpaceCredentials {
        if let cached = credentials[space] { return cached }
        let made = try await access.credentials(for: space)
        credentials[space] = made
        return made
    }

    /// A client reading `did`'s repo at its PDS, with a space's credential.
    private func client(for did: String, credentials: SpaceCredentials) async throws -> XRPCClient {
        guard let identity = await identity(of: did) else {
            throw ATDriveError.identity("couldn't find \(did)'s PDS")
        }
        return XRPCClient(service: identity.pds, credentials: credentials, transport: access.transport)
    }

    private func identity(of did: String) async -> ResolvedIdentity? {
        if let known = identities[did] { return known }
        if unresolvable.contains(did) { return nil }
        guard let resolved = try? await access.resolver.resolve(did) else {
            unresolvable.insert(did)
            return nil
        }
        identities[did] = resolved
        return resolved
    }

    // MARK: Spaces added by address

    /// The spaces added by address, from the home drive (for every device).
    public func addedSpaces() async throws -> [String] {
        guard let home else { return [] }
        var spaces: [String] = []
        var cursor: String?
        repeat {
            let page = try await client.listRawSpaceRecords(
                space: home.space, repo: account, collection: Lexicon.addedSpace, cursor: cursor)
            for record in page.records {
                if let added = home.read(
                    record.value, as: AddedSpace.self, collection: Lexicon.addedSpace, rkey: record.rkey)
                {
                    spaces.append(added.space)
                }
            }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return spaces.sorted()
    }

    /// Adds a space by its address (`at://<handle or DID>/space/<type>/<key>`), for every device.
    /// Adding one that's there already is fine. Returns its URI (with the authority's DID).
    @discardableResult
    public func add(_ address: String) async throws -> String {
        guard let home else { throw AppDataError.notAdded(address) }
        let space = try await parse(address)
        let rkey = AddedSpace.key(for: space)
        let value = try home.stored(AddedSpace(space: space), collection: Lexicon.addedSpace, rkey: rkey)
        do {
            try await home.apply([.create(collection: Lexicon.addedSpace, rkey: rkey, value: value)])
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
        } catch let error as XRPCError where Self.isScopeRefusal(error) {
            throw AppDataError.needsSignIn
        }
        return space
    }

    /// Takes a space added by address out of the apps view (on every device).
    public func remove(_ address: String) async throws {
        guard let home else { throw AppDataError.notAdded(address) }
        let space = try await parse(address)
        do {
            try await home.apply([.delete(collection: Lexicon.addedSpace, rkey: AddedSpace.key(for: space))])
        } catch let error as XRPCError where error.error == "RecordNotFound" {
            throw AppDataError.notAdded(space)
        }
    }

    /// A space's URI from its address, the authority given by handle or DID.
    public func parse(_ address: String) async throws -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("at://") else { throw AppDataError.notASpace(address) }
        let parts = text.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[1] == "space", !parts[0].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty else {
            throw AppDataError.notASpace(address)
        }
        var authority = parts[0]
        if !authority.hasPrefix("did:") {
            guard let did = try? await access.resolver.resolve(authority).did else {
                throw ATDriveError.identity("couldn't find \(authority)")
            }
            authority = did
        }
        let space = XRPCClient.spaceURI(authority: authority, type: parts[2], key: parts[3])
        guard XRPCClient.spaceParts(space) != nil else { throw AppDataError.notASpace(address) }
        guard Self.isShown(space) else { throw AppDataError.driveSpace }
        return space
    }

    // MARK: Helpers

    /// The PDS refused for lack of scope: the session was granted less than this needs.
    static func isScopeRefusal(_ error: XRPCError) -> Bool {
        ["InsufficientScope", "ScopeMissing", "InvalidScope", "insufficient_scope"].contains(error.error ?? "")
            || (error.status == 403 && (error.message ?? "").lowercased().contains("scope"))
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? XRPCError { return error.error ?? "HTTP \(error.status)" }
        return String(describing: error)
    }
}

// MARK: - As files

/// The apps view as files and folders, read-only:
///
///     <authority>/<space type> – <space key>/<writer>/<collection>/<rkey>.json
///                                                     /<collection>/<rkey>.blobs/<cid>.<ext>
///
/// Accounts by handle (DID if it doesn't resolve). Records are pretty-printed JSON as stored,
/// `$type`, blob refs and `$link`/`$bytes` included; the blobs a record references are beside it.
/// A space with a problem holds `UNREADABLE.txt`, saying what's missing and why.
///
/// Item IDs stay the same as long as the thing does (handles changing renames, nothing else).
public struct AppTree: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public enum Content: Sendable, Equatable {
            case folder
            /// A record, as pretty-printed JSON.
            case record(Data)
            /// A blob a record references.
            case blob(space: String, repo: String, cid: String, size: Int?)
            /// An explanation (`UNREADABLE.txt`).
            case note(String)
        }

        public var id: String
        /// `nil` at the top.
        public var parent: String?
        public var name: String
        public var content: Content

        public var isFolder: Bool { content == .folder }

        public var size: Int? {
            switch content {
            case .folder: nil
            case .record(let data): data.count
            case .blob(_, _, _, let size): size
            case .note(let text): text.utf8.count
            }
        }

        /// Changes exactly when the contents do: the record's or blob's CID, or the note.
        public var contentVersion: String {
            switch content {
            case .folder: "folder"
            case .record(let data): "r" + Self.hash(data)
            case .blob(_, _, let cid, _): cid
            case .note(let text): "n" + Self.hash(Data(text.utf8))
            }
        }

        static func hash(_ data: Data) -> String {
            SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        }
    }

    public static let unreadableName = "UNREADABLE.txt"

    /// By ID.
    public private(set) var items: [String: Item] = [:]
    private var childIDs: [String: [String]] = [:]
    /// Changes whenever anything in the tree does: the File Provider sync anchor.
    public private(set) var anchor = ""

    private static let rootKey = ""

    public init(_ snapshot: AppDataSnapshot) {
        let handles = snapshot.handles
        func name(of did: String) -> String { handles[did] ?? did }
        for space in snapshot.spaces.values {
            let authority = "a|\(space.authority)"
            add(Item(id: authority, parent: nil, name: name(of: space.authority), content: .folder))
            let spaceID = "s|\(space.uri)"
            add(Item(id: spaceID, parent: authority, name: "\(space.type) – \(space.key)", content: .folder))
            if let problem = space.problem {
                add(
                    Item(
                        id: "u|\(space.uri)", parent: spaceID, name: Self.unreadableName,
                        content: .note(Self.explain(problem, space: space, account: snapshot.account))))
            }
            for repo in space.repos.values {
                let writer = "w|\(space.uri)|\(repo.did)"
                add(Item(id: writer, parent: spaceID, name: name(of: repo.did), content: .folder))
                for record in repo.records.values {
                    let collection = "c|\(space.uri)|\(repo.did)|\(record.collection)"
                    add(Item(id: collection, parent: writer, name: record.collection, content: .folder))
                    let base = "\(space.uri)|\(repo.did)|\(record.collection)|\(record.rkey)"
                    add(
                        Item(
                            id: "r|\(base)", parent: collection, name: "\(record.rkey).json",
                            content: .record(record.value.prettySerialized())))
                    let blobs = Self.blobs(in: record.value)
                    guard !blobs.isEmpty else { continue }
                    let folder = "b|\(base)"
                    add(Item(id: folder, parent: collection, name: "\(record.rkey).blobs", content: .folder))
                    for blob in blobs {
                        add(
                            Item(
                                id: "f|\(base)|\(blob.cid)", parent: folder,
                                name: "\(blob.cid).\(Self.fileExtension(for: blob.mimeType))",
                                content: .blob(space: space.uri, repo: repo.did, cid: blob.cid, size: blob.size)))
                    }
                }
            }
        }
        for key in childIDs.keys {
            childIDs[key]!.sort { items[$0]!.name.localizedStandardCompare(items[$1]!.name) == .orderedAscending }
        }
        var hasher = SHA256()
        for item in items.values.sorted(by: { $0.id < $1.id }) {
            hasher.update(data: Data("\(item.id)\t\(item.parent ?? "")\t\(item.name)\t\(item.contentVersion)\n".utf8))
        }
        anchor = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func add(_ item: Item) {
        guard items[item.id] == nil else { return }
        items[item.id] = item
        childIDs[item.parent ?? Self.rootKey, default: []].append(item.id)
    }

    // MARK: Looking things up

    /// A folder's items (`nil`: the top), by name.
    public func children(of id: String?) -> [Item] {
        (childIDs[id ?? Self.rootKey] ?? []).compactMap { items[$0] }
    }

    /// Everything inside a folder, at any depth.
    public func descendants(of id: String?) -> [Item] {
        var found: [Item] = []
        var queue = children(of: id)
        while let next = queue.popLast() {
            found.append(next)
            if next.isFolder { queue += children(of: next.id) }
        }
        return found
    }

    /// The item at a path (`nil` for the top); throws if there's none.
    public func locate(_ path: DrivePath) throws -> Item? {
        var current: Item?
        for name in path.components {
            guard let next = children(of: current?.id).first(where: { $0.name == name }) else {
                throw ATDriveError.notFound(path.description)
            }
            current = next
        }
        return current
    }

    public func path(of id: String) -> DrivePath {
        var names: [String] = []
        var current = items[id]
        while let item = current {
            names.append(item.name)
            current = item.parent.flatMap { items[$0] }
        }
        return DrivePath(components: names.reversed())
    }

    /// What changed since `old`: items new or different (contents, name or folder), and the IDs
    /// of items gone.
    public func changes(since old: AppTree) -> (updated: [Item], deleted: [String]) {
        let updated = items.values.filter { item in
            guard let before = old.items[item.id] else { return true }
            return before != item
        }
        let deleted = old.items.keys.filter { items[$0] == nil }
        // Folders before what's in them.
        return (updated.sorted { path(of: $0.id).components.count < path(of: $1.id).components.count }, deleted)
    }

    // MARK: Building

    /// What `UNREADABLE.txt` says.
    static func explain(_ problem: AppSpaceProblem, space: AppSpace, account: String) -> String {
        let shown =
            space.repos.isEmpty
            ? "Nothing in it is shown"
            : Array(space.repos.keys) == [account]
                ? "Only your own records in it are shown" : "What's shown may be out of date"
        switch problem {
        case .access:
            return "ATDrive can't read this space: \(problem).\n\n\(shown).\n\nSpace: \(space.uri)\n"
        case .unreachable:
            return
                "ATDrive couldn't read this space just now: \(problem). It tries again on the next check.\n\n"
                + "\(space.repos.isEmpty ? "Nothing in it is shown yet" : "What's shown is what it read last time").\n\n"
                + "Space: \(space.uri)\n"
        }
    }

    /// The blobs a record references (`{"$type": "blob", "ref": {"$link": cid}, …}`), each once.
    static func blobs(in value: JSONValue) -> [(cid: String, mimeType: String?, size: Int?)] {
        var found: [(cid: String, mimeType: String?, size: Int?)] = []
        var seen: Set<String> = []
        var stack = [value]
        while let next = stack.popLast() {
            switch next {
            case .object(let object):
                if object["$type"]?.string == "blob", let cid = object["ref"]?["$link"]?.string {
                    if seen.insert(cid).inserted {
                        var size: Int?
                        if case .integer(let bytes) = object["size"] { size = Int(bytes) }
                        found.append((cid, object["mimeType"]?.string, size))
                    }
                } else {
                    stack += object.keys.sorted().reversed().compactMap { object[$0] }
                }
            case .array(let values): stack += values.reversed()
            default: break
            }
        }
        return found
    }

    static func fileExtension(for mimeType: String?) -> String {
        let known = [
            "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic",
            "image/avif": "avif", "image/svg+xml": "svg", "video/mp4": "mp4", "video/quicktime": "mov",
            "video/webm": "webm", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "ogg", "audio/wav": "wav",
            "application/pdf": "pdf", "text/plain": "txt", "text/markdown": "md", "text/html": "html",
            "text/csv": "csv", "application/json": "json", "application/zip": "zip",
        ]
        let type = mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return type.flatMap { known[$0] } ?? "bin"
    }
}

import Crypto
import Foundation

// Spaces (#28): everything in the spaces the account is in, not just ATDrive's files, as a
// read-only folder at the top of the drive (`SpacesFolder` in `Mounts.swift`). Other atproto apps
// keep data in spaces (a Bulletin board's notes, say), and people share spaces with you. This
// reads them all, read-only: ATDrive writes with `validate = false`, so letting edits through
// could quietly corrupt another app's data.
//
// Where it comes from:
// 1. `listSpaces` on the account's own PDS: the spaces it owns or has written to, with its repo's
//    revision in each. Its own repos are read with its session.
// 2. Everyone else's repos in those spaces: a credential from the space's host (as for shares,
//    `SpaceCredentials`), `listWriters` there, then each writer's repo at their own PDS.
// 3. Spaces shared with the account that it never wrote to, which `listSpaces` doesn't list (#56):
//    by address, from `spaces.include` in config.toml (`SpacesSettings`). `spaces.exclude` hides
//    any space.
//
// ATDrive's own drive spaces aren't shown: they're the drive. A space that won't let ATDrive in
// (`allowedApps`, say) is shown with why, not hidden.

/// What the Spaces folder shows (`spaces.*` in config.toml, while `spaces.enabled` is on).
public struct SpacesSettings: Sendable, Equatable, Codable {
    /// The folder's name, at the top of the drive.
    public var folder: String
    /// Addresses of spaces to show that aren't found by themselves.
    public var include: [String]
    /// Addresses of spaces not to show.
    public var exclude: [String]

    public init(folder: String = "Spaces", include: [String] = [], exclude: [String] = []) {
        self.folder = folder
        self.include = include
        self.exclude = exclude
    }

    /// Whether `text` looks like a space's address: `at://<handle or DID>/space/<type>/<key>`.
    public static func isAddress(_ text: String) -> Bool {
        guard text.hasPrefix("at://") else { return false }
        let parts = text.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[1] == "space" && !parts[0].isEmpty && !parts[2].isEmpty
            && !parts[3].isEmpty
    }
}

public enum SpaceDataError: Error, Equatable, CustomStringConvertible {
    case notASpace(String)
    /// ATDrive's own spaces are the drive (`atdrive open-share` for one shared with you).
    case driveSpace
    /// Spaces are off (`spaces.enabled` in config.toml).
    case off
    /// The session wasn't granted what this needs: sign in again.
    case needsSignIn

    public var description: String {
        switch self {
        case .notASpace(let text):
            "\(text) isn't a space's address (at://<handle or DID>/space/<type>/<key>)"
        case .driveSpace:
            "that's an ATDrive space: open it with `atdrive open-share <link>` to put it in your drive"
        case .off:
            "Spaces is off: set spaces.enabled = true in config.toml (`atdrive config` shows where it is)"
        case .needsSignIn:
            "this sign-in can't read your other spaces. Sign in again (`atdrive login <handle>`) to grant it"
        }
    }
}

/// Reads the spaces view for the signed-in account: `update` gives a `Snapshot`, and `contents`
/// reads a file in its tree. Credentials, identities and space type titles are kept between
/// updates.
public actor SpaceData {
    /// A record in a space, as stored.
    public struct Record: Sendable, Equatable {
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

    /// One account's records in a space, at a revision.
    public struct Repo: Sendable, Equatable {
        public var did: String
        public var rev: String
        /// By `collection/rkey`.
        public var records: [String: Record]

        public init(did: String, rev: String, records: [String: Record]) {
            self.did = did
            self.rev = rev
            self.records = records
        }
    }

    /// Why some of a space isn't shown.
    public enum Problem: Sendable, Equatable, CustomStringConvertible {
        /// Its host refused: not shared with this account (any more), deleted, or not letting
        /// ATDrive in. Other people's records in it aren't shown.
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

    /// A space the account is in, with everyone's records in it that could be read.
    public struct Space: Sendable, Equatable {
        public var uri: String
        public var authority: String
        public var type: String
        public var key: String
        /// From `spaces.include`, rather than (only) listed by the account's PDS.
        public var included: Bool
        /// By DID.
        public var repos: [String: Repo]
        public var problem: Problem?

        public init(uri: String, included: Bool, repos: [String: Repo] = [:], problem: Problem? = nil) {
            let parts = XRPCClient.spaceParts(uri)
            self.uri = uri
            authority = parts?.authority ?? ""
            type = parts?.type ?? ""
            key = parts?.key ?? ""
            self.included = included
            self.repos = repos
            self.problem = problem
        }
    }

    /// Everything in the spaces view at one moment. Give it to the next `update`, which reads
    /// again only the repos whose revision moved.
    public struct Snapshot: Sendable, Equatable {
        public var account: String
        /// By URI.
        public var spaces: [String: Space]
        /// Handles of the accounts in it, by DID, where they resolved.
        public var handles: [String: String]
        /// Space types' titles, from their declarations (`"AtmoBoards Forum"`), where they
        /// resolved.
        public var titles: [String: String]
        /// Spaces found but not shown (`spaces.exclude`), by URI.
        public var excluded: Set<String>
        /// Addresses in `spaces.include` or `spaces.exclude` that couldn't be used, and why.
        public var unusable: [String: String]

        public init(
            account: String, spaces: [String: Space], handles: [String: String] = [:], titles: [String: String] = [:],
            excluded: Set<String> = [], unusable: [String: String] = [:]
        ) {
            self.account = account
            self.spaces = spaces
            self.handles = handles
            self.titles = titles
            self.excluded = excluded
            self.unusable = unusable
        }

        /// As files and folders.
        public var tree: SpaceTree { SpaceTree(self) }
    }

    public let client: XRPCClient
    public let account: String
    let access: SpaceAccess
    private var credentials: [String: SpaceCredentials] = [:]
    private var identities: [String: ResolvedIdentity] = [:]
    private var unresolvable: Set<String> = []
    /// Space types' titles, `nil` where a type's declaration has none or didn't resolve.
    private var titles: [String: String?] = [:]
    /// Addresses as URIs (with the authority's DID), or why one can't be.
    private var addresses: [String: Result<String, SpaceDataError>] = [:]

    public init(client: XRPCClient, account: String, access: SpaceAccess) {
        self.client = client
        self.account = account
        self.access = access
    }

    /// Whether a space belongs in the spaces view: not ATDrive's own (that's the drive).
    public static func isShown(_ space: String) -> Bool {
        guard let parts = XRPCClient.spaceParts(space) else { return false }
        return parts.type != Lexicon.driveSpace
    }

    // MARK: Reading

    /// The spaces now: those the account's PDS lists and those `settings.include`s, minus those
    /// it `exclude`s. Repos whose revision hasn't moved since `previous` are taken from it, and
    /// the rest follow their change feed from there (or are listed again in full). A space that
    /// can't be read is in it with its problem; one that can't be reached keeps what `previous`
    /// had. Throws only if the account's own PDS can't be read.
    public func update(_ previous: Snapshot? = nil, settings: SpacesSettings = SpacesSettings()) async throws
        -> Snapshot
    {
        let views: [SpaceView]
        do {
            views = try await client.listSpaceViews()
        } catch let error as XRPCError where Self.isScopeRefusal(error) {
            throw SpaceDataError.needsSignIn
        }
        var unusable: [String: String] = [:]
        var include: Set<String> = []
        var exclude: Set<String> = []
        for (addresses, excluding) in [(settings.include, false), (settings.exclude, true)] {
            for address in addresses {
                switch await uri(of: address) {
                case .success(let uri):
                    if excluding { exclude.insert(uri) } else { include.insert(uri) }
                case .failure(let why): unusable[address] = why.description
                }
            }
        }
        var known: [String: (rev: String?, included: Bool)] = [:]
        var excluded: Set<String> = []
        for view in views where Self.isShown(view.space) { known[view.space] = (view.repoRev, false) }
        for space in include { known[space] = (known[space]?.rev, true) }
        for space in exclude where known.removeValue(forKey: space) != nil { excluded.insert(space) }
        var spaces: [String: Space] = [:]
        await withTaskGroup(of: Space.self) { group in
            for (uri, info) in known {
                let before = previous?.spaces[uri]
                group.addTask { await self.read(uri, ownRev: info.rev, included: info.included, previous: before) }
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
        var titles: [String: String] = [:]
        for type in Set(spaces.values.map(\.type)) {
            if let title = await title(of: type) { titles[type] = title }
        }
        return Snapshot(
            account: account, spaces: spaces, handles: handles, titles: titles, excluded: excluded, unusable: unusable)
    }

    /// An address as a URI: cached, as resolving a handle is a request.
    private func uri(of address: String) async -> Result<String, SpaceDataError> {
        if let known = addresses[address] { return known }
        let result: Result<String, SpaceDataError>
        do {
            result = .success(try await parse(address))
        } catch let error as SpaceDataError {
            result = .failure(error)
        } catch {
            // Couldn't resolve the handle just now: try again next time.
            return .failure(.notASpace(address))
        }
        addresses[address] = result
        return result
    }

    private func read(_ uri: String, ownRev: String?, included: Bool, previous: Space?) async -> Space {
        var space = Space(uri: uri, included: included)
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
    static func readRepo(_ client: XRPCClient, space: String, did: String, rev: String, previous: Repo?)
        async throws -> Repo
    {
        if let previous {
            if previous.rev == rev { return previous }
            if let followed = try? await follow(client, space: space, did: did, from: previous) { return followed }
        }
        var records: [String: Record] = [:]
        var cursor: String?
        repeat {
            let page = try await client.listRawSpaceRecords(space: space, repo: did, collection: nil, cursor: cursor)
            for record in page.records {
                guard let collection = record.collection else {
                    throw ATDriveError.unexpectedResponse(
                        "com.atproto.space.listRecords: a record without its collection")
                }
                records["\(collection)/\(record.rkey)"] = Record(
                    collection: collection, rkey: record.rkey, cid: record.cid, value: record.value ?? .null)
            }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return Repo(did: did, rev: rev, records: records)
    }

    /// `previous` brought up to date with the change feed; `nil` if the feed has a gap (it was
    /// compacted, or `previous` was listed mid-write), so it has to be listed again.
    static func follow(_ client: XRPCClient, space: String, did: String, from previous: Repo) async throws -> Repo? {
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
                    records[key] = Record(collection: op.collection, rkey: op.rkey, cid: cid, value: op.value ?? .null)
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
        return Repo(did: did, rev: head, records: records)
    }

    /// What a file in the tree holds: a record as JSON, or a blob (downloaded). Checked against
    /// its SHA-256.
    public func contents(of item: SpaceTree.Item) async throws -> Data {
        let data = try await unchecked(item)
        if let expected = item.sha256, SHA256.hash(data: data).hexString != expected {
            throw ATDriveError.integrity("\(item.name) isn't what its record says it is")
        }
        return data
    }

    private func unchecked(_ item: SpaceTree.Item) async throws -> Data {
        switch item.content {
        case .folder: throw ATDriveError.isAFolder(item.name)
        case .record(let data): return data
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

    /// A space type's title, from its declaration; looked up once.
    private func title(of type: String) async -> String? {
        if let known = titles[type] { return known }
        let title = try? await client.spaceTypeTitle(type)
        titles[type] = .some(title)
        return title
    }

    /// A space's URI from its address, the authority given by handle or DID.
    public func parse(_ address: String) async throws -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("at://") else { throw SpaceDataError.notASpace(address) }
        let parts = text.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[1] == "space", !parts[0].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty else {
            throw SpaceDataError.notASpace(address)
        }
        var authority = parts[0]
        if !authority.hasPrefix("did:") {
            guard let did = try? await access.resolver.resolve(authority).did else {
                throw ATDriveError.identity("couldn't find \(authority)")
            }
            authority = did
        }
        let space = XRPCClient.spaceURI(authority: authority, type: parts[2], key: parts[3])
        guard XRPCClient.spaceParts(space) != nil else { throw SpaceDataError.notASpace(address) }
        guard Self.isShown(space) else { throw SpaceDataError.driveSpace }
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

/// The spaces view as files and folders, read-only, by app (space type), then space, then record
/// type:
///
///     Bulletin/home/note/3l2kabc.json                 your record in your space
///     Bulletin/home/note/@bob.test 3l2mxyz.json       someone else's, in it too
///     Bulletin/home/note/@bob.test 3l2mxyz.blobs/bafkrei….png
///     Bulletin/@carol.test kitchen/note/…             a space someone else owns
///
/// - An app's folder is its space type's title (`"AtmoBoards Forum"`), else its domain
///   (`bulletin.my` for `my.bulletin.board`).
/// - A record type is named without the space type's domain (`note` for `my.bulletin.note`), or
///   in full if it's from another domain.
/// - Records are pretty-printed JSON as stored, `$type`, blob refs and `$link`/`$bytes` included;
///   the blobs a record references are beside it. Other people's start with their handle (DID if
///   it doesn't resolve), so they sort together.
/// - A space with a problem is marked (`Item.unreadable`), with why.
///
/// Item IDs stay the same as long as the thing does (handles changing renames, nothing else).
public struct SpaceTree: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public enum Content: Sendable, Equatable {
            case folder
            /// A record, as pretty-printed JSON.
            case record(Data)
            /// A blob a record references.
            case blob(space: String, repo: String, cid: String, size: Int?)
        }

        public var id: String
        /// `nil` at the top.
        public var parent: String?
        public var name: String
        public var content: Content
        /// For a space some of which can't be read: why.
        public var unreadable: String?
        /// For a record and its blobs: when it was made (its `createdAt`, else its key's time if
        /// that's a TID).
        public var date: Date?

        public init(
            id: String, parent: String?, name: String, content: Content, unreadable: String? = nil, date: Date? = nil
        ) {
            self.id = id
            self.parent = parent
            self.name = name
            self.content = content
            self.unreadable = unreadable
            self.date = date
        }

        public var isFolder: Bool { content == .folder }

        public var size: Int? {
            switch content {
            case .folder: nil
            case .record(let data): data.count
            case .blob(_, _, _, let size): size
            }
        }

        /// A file's hex SHA-256: of the JSON, or a blob's from its CID.
        public var sha256: String? {
            switch content {
            case .folder: nil
            case .record(let data): SHA256.hash(data: data).hexString
            case .blob(_, _, let cid, _): CID.sha256(ofBlob: cid)
            }
        }

        /// Changes exactly when the contents do: the record's or blob's CID.
        public var contentVersion: String {
            switch content {
            case .folder: "folder"
            case .record(let data): "r" + SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
            case .blob(_, _, let cid, _): cid
            }
        }
    }

    /// By ID.
    public private(set) var items: [String: Item] = [:]
    private var childIDs: [String: [String]] = [:]
    /// Changes whenever anything in the tree does: the File Provider sync anchor.
    public private(set) var anchor = ""

    private static let rootKey = ""

    public init(_ snapshot: SpaceData.Snapshot) {
        let handles = snapshot.handles
        func person(_ did: String) -> String { "@\(handles[did] ?? did)" }
        let apps = Self.appNames(Set(snapshot.spaces.values.map(\.type)), titles: snapshot.titles)
        for space in snapshot.spaces.values {
            let app = "t|\(space.type)"
            add(Item(id: app, parent: nil, name: apps[space.type]!, content: .folder))
            let spaceID = "s|\(space.uri)"
            let spaceName = space.authority == snapshot.account ? space.key : "\(person(space.authority)) \(space.key)"
            add(
                Item(
                    id: spaceID, parent: app, name: spaceName, content: .folder,
                    unreadable: space.problem?.description))
            for repo in space.repos.values {
                let prefix = repo.did == snapshot.account ? "" : "\(person(repo.did)) "
                for record in repo.records.values {
                    let collection = "c|\(space.uri)|\(record.collection)"
                    add(
                        Item(
                            id: collection, parent: spaceID,
                            name: Self.shortName(of: record.collection, in: space.type), content: .folder))
                    let base = "\(space.uri)|\(repo.did)|\(record.collection)|\(record.rkey)"
                    let date = Self.date(of: record)
                    add(
                        Item(
                            id: "r|\(base)", parent: collection, name: "\(prefix)\(record.rkey).json",
                            content: .record(record.value.prettySerialized()), date: date))
                    // Only blobs whose CID says their SHA-256 (all of atproto's): a file is
                    // checked against it, and a synced folder compares by it.
                    let blobs = Self.blobs(in: record.value).filter { CID.sha256(ofBlob: $0.cid) != nil }
                    guard !blobs.isEmpty else { continue }
                    let folder = "b|\(base)"
                    add(
                        Item(
                            id: folder, parent: collection, name: "\(prefix)\(record.rkey).blobs", content: .folder,
                            date: date))
                    for blob in blobs {
                        add(
                            Item(
                                id: "f|\(base)|\(blob.cid)", parent: folder,
                                name: "\(blob.cid).\(Self.fileExtension(for: blob.mimeType))",
                                content: .blob(space: space.uri, repo: repo.did, cid: blob.cid, size: blob.size),
                                date: date))
                    }
                }
            }
        }
        for key in childIDs.keys {
            childIDs[key]!.sort { items[$0]!.name.localizedStandardCompare(items[$1]!.name) == .orderedAscending }
        }
        var hasher = SHA256()
        for item in items.values.sorted(by: { $0.id < $1.id }) {
            let line =
                "\(item.id)\t\(item.parent ?? "")\t\(item.name)\t\(item.contentVersion)\t\(item.unreadable ?? "")\n"
            hasher.update(data: Data(line.utf8))
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

    /// What changed since `old`: items new or different (contents, name, folder or problem), and
    /// the IDs of items gone.
    public func changes(since old: SpaceTree) -> (updated: [Item], deleted: [String]) {
        let updated = items.values.filter { item in
            guard let before = old.items[item.id] else { return true }
            return before != item
        }
        let deleted = old.items.keys.filter { items[$0] == nil }
        // Folders before what's in them.
        return (updated.sorted { path(of: $0.id).components.count < path(of: $1.id).components.count }, deleted)
    }

    // MARK: Names

    /// Each space type's folder: its title, else its domain (`my.bulletin.board` →
    /// `bulletin.my`). Types that would share a name get their last segment too.
    static func appNames(_ types: Set<String>, titles: [String: String]) -> [String: String] {
        var names: [String: String] = [:]
        for type in types {
            let title = titles[type]?.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "∕")
            names[type] = title.flatMap { $0.isEmpty ? nil : $0 } ?? domain(of: type)
        }
        let clashing = Dictionary(grouping: names.keys, by: { names[$0]! }).filter { $0.value.count > 1 }
        for (name, types) in clashing {
            for type in types { names[type] = "\(name) (\(type.split(separator: ".").last!))" }
        }
        return names
    }

    /// When a record was made: its `createdAt`, else its key's time if that's a TID.
    static func date(of record: SpaceData.Record) -> Date? {
        record.value["createdAt"]?.string.flatMap(Timestamp.parse) ?? TID.date(record.rkey)
    }

    /// The domain an NSID's authority is: `my.bulletin.board` → `bulletin.my`.
    static func domain(of nsid: String) -> String {
        nsid.split(separator: ".").dropLast().reversed().joined(separator: ".")
    }

    /// A record type's folder in a space of `type`: without the type's authority if it shares it
    /// (`my.bulletin.note` → `note`), else in full.
    static func shortName(of collection: String, in type: String) -> String {
        let authority = type.split(separator: ".").dropLast().joined(separator: ".") + "."
        guard collection.hasPrefix(authority), collection.count > authority.count else { return collection }
        return String(collection.dropFirst(authority.count))
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

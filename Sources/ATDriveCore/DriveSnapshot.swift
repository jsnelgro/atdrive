import Foundation

/// Every record in the drive's repo, in every collection (collection → rkey → CID), at a
/// revision. Full listings and the change feed both keep it current, so it's the one place to
/// check what we hold against the drive's commit (`check`).
public struct RepoState: Sendable, Equatable {
    public internal(set) var revision: String?
    /// The commit's `data` at `revision` (see `RepoCommit`).
    public internal(set) var data: Data?
    /// Changed only through `set`, which keeps `hash` in step.
    public private(set) var records: [String: [String: String]] = [:]
    /// The LtHash over `records`, kept current one record at a time, so a check costs the same
    /// however big the drive is.
    public private(set) var hash: RepoSetHash

    public init(revision: String? = nil, data: Data? = nil, records: [String: [String: String]] = [:]) {
        self.init(revision: revision, data: data, records: records, hash: nil)
    }

    /// `hash` must be the one over `records` (e.g. saved with them); `nil` computes it.
    init(revision: String?, data: Data?, records: [String: [String: String]], hash: RepoSetHash?) {
        self.revision = revision
        self.data = data
        self.records = records
        self.hash = hash ?? Self.hash(of: records)
    }

    /// The hash from scratch: one BLAKE3 expansion per record.
    static func hash(of records: [String: [String: String]]) -> RepoSetHash {
        var hash = RepoSetHash()
        for (collection, cids) in records {
            for (rkey, cid) in cids { hash.add(collection: collection, rkey: rkey, cid: cid) }
        }
        return hash
    }

    public func cid(_ collection: String, _ rkey: String) -> String? { records[collection]?[rkey] }

    mutating func set(_ collection: String, _ rkey: String, cid: String?) {
        let held = records[collection]?[rkey]
        guard cid != held else { return }
        // The CID we hold, not the op's `prev`: the hash follows `records`, even when catching up
        // on a listing that already has some of the ops.
        hash.applyOp(collection: collection, rkey: rkey, prev: held, cid: cid)
        records[collection, default: [:]][rkey] = cid
        if records[collection]?.isEmpty == true { records[collection] = nil }
    }

    /// Whether these are exactly the records the commit covers: an LtHash over
    /// `collection/rkey/cid` for every record, in every collection, compared with `commit.data`.
    /// That catches anything a compacted change feed hid.
    public func check(_ commit: RepoCommit) -> Bool { hash.matches(commitData: commit.data) }
}

/// The change feed doesn't connect to what we hold: an op's `prev` isn't the CID we have, a
/// current value is missing, the revision moved without ops, or the records don't match the
/// commit. The fix is a full listing.
public struct ChangeFeedGap: Error, CustomStringConvertible, Equatable {
    public var description: String
}

/// The drive as this device last fetched it: every record's CID (`repo`), the file tree
/// (`tree`, with the node records it can't read), its history (`history`) and its `settings`.
/// `Drive.update` keeps it current by applying the change feed, and lists everything again when
/// that can't be trusted.
public struct DriveSnapshot: Sendable {
    public private(set) var repo: RepoState
    public private(set) var tree: DriveTree
    /// Every version record: what changed, when, and the drive as it was.
    public private(set) var history = DriveHistory()
    /// The `chunks` records, by key, as stored: the rest of chunk lists too long for the version
    /// holding them. Node and version records are read with them.
    public private(set) var continuations: [String: JSONValue] = [:]
    /// `nil` if the drive has no settings record, or one this device can't read (see
    /// `Drive.readSettings`): then the defaults apply.
    public private(set) var settings: DriveSettings?
    /// The settings record as stored, while it can't be read here, to read again once it can.
    private var unreadableSettings: JSONValue?
    /// When the whole drive was last listed.
    public private(set) var listedAt: Date
    /// Whether that listing happened in this process. A saved snapshot is listed again when
    /// first used, unless it was checked against the commit (`RepoState.check`).
    public private(set) var listedThisRun: Bool
    /// Whether the records were checked against the latest commit and matched. Then every
    /// update is checked too (a mismatch is a gap), so no periodic listing is needed.
    public private(set) var verified = false
    /// Why the records aren't `verified`, when a check failed in this process: a full listing
    /// didn't match its commit (say the server hashes differently). Listing again straight away
    /// wouldn't help, so the listing is kept, and the drive is listed at start and every hour
    /// until a check passes.
    public private(set) var mismatch: ChangeFeedGap?

    /// How often the whole drive is listed while the records don't match the commit.
    public static let fullListingInterval: TimeInterval = 60 * 60

    /// The revision it's at; `nil` if the drive has no repo (gone, or never written to).
    public var revision: String? { repo.revision }

    /// A drive with no repo: gone, or never written to.
    public init(listedAt: Date = Date()) {
        repo = RepoState()
        tree = DriveTree([])
        self.listedAt = listedAt
        listedThisRun = true
    }

    /// A full listing (every collection) taken after `commit`, so at least as new as it. Its
    /// records are read (and unsealed) by `drive`.
    init(
        listing: [(collection: String, rkey: String, cid: String, value: JSONValue?)], commit: RepoCommit,
        listedAt: Date, reading drive: Drive
    ) {
        var repo = RepoState(revision: commit.rev, data: commit.data)
        var entries: [NodeEntry] = []
        var history = DriveHistory()
        var continuations: [String: JSONValue] = [:]
        for record in listing where record.collection == Lexicon.chunks {
            continuations[record.rkey] = record.value
        }
        for record in listing {
            repo.set(record.collection, record.rkey, cid: record.cid)
            switch record.collection {
            case Lexicon.node:
                entries.append(
                    drive.readNode(id: record.rkey, cid: record.cid, value: record.value, continuations: continuations))
            case Lexicon.version:
                history.set(
                    drive.readVersion(
                        id: record.rkey, cid: record.cid, value: record.value, continuations: continuations))
            case Lexicon.settings where record.rkey == Lexicon.settingsKey:
                (settings, unreadableSettings) = Self.readSettings(record.value, drive: drive)
            default: break
            }
        }
        self.history = history
        self.continuations = continuations
        self.repo = repo
        tree = DriveTree(entries)
        self.listedAt = listedAt
        listedThisRun = true
    }

    /// Whether the next update should list the whole drive rather than follow the change feed.
    public func needsFullListing(at now: Date = Date()) -> Bool {
        guard revision != nil else { return true }
        if verified { return false }
        return !listedThisRun || now.timeIntervalSince(listedAt) >= Self.fullListingInterval
    }

    /// Applies the change feed since `revision`, then checks the records against the commit.
    /// Nothing changes if it throws.
    ///
    /// `strict` checks that each op's `prev` is the CID we hold: off only when catching up on a
    /// listing, which may already include some of the ops. Either way, an op whose value is
    /// missing though nothing later replaced it, or a revision that moved without ops, is a gap.
    /// So is a failed check, once the records have matched: before that (a fresh listing, or
    /// one that didn't match), a failed check is noted in `mismatch` instead, so a server whose
    /// hash we can't match isn't listed again on every update.
    mutating func apply(_ changes: DriveChanges, strict: Bool, reading drive: Drive) throws {
        guard let commit = changes.commit else {
            self = DriveSnapshot(listedAt: listedAt)
            return
        }
        let ops = changes.ops
        if commit.rev != revision, ops.last?.rev != commit.rev {
            throw ChangeFeedGap(description: "the drive is at \(commit.rev), but the change feed doesn't get there")
        }
        if commit.rev == revision, !ops.isEmpty {
            throw ChangeFeedGap(description: "the change feed has writes past the drive's revision")
        }
        struct Key: Hashable {
            var collection: String
            var rkey: String
        }
        var latest: [Key: Int] = [:]
        for (index, op) in ops.enumerated() { latest[Key(collection: op.collection, rkey: op.rkey)] = index }

        var repo = self.repo
        var nodes = tree.nodes
        var unreadable = tree.unreadable
        var history = self.history
        var continuations = self.continuations
        var settings = (settings, unreadableSettings)
        // `chunks` records first, so the nodes and versions they continue are read with them.
        // Each record's ops stay in order.
        let order =
            ops.indices.filter { ops[$0].collection == Lexicon.chunks }
            + ops.indices.filter { ops[$0].collection != Lexicon.chunks }
        for index in order {
            let op = ops[index]
            let held = repo.cid(op.collection, op.rkey)
            if strict, op.prev != held {
                throw ChangeFeedGap(
                    description: "\(op.collection)/\(op.rkey) changed from \(op.prev ?? "nothing"), "
                        + "but we had \(held ?? "nothing")")
            }
            repo.set(op.collection, op.rkey, cid: op.cid)
            let isLatest = latest[Key(collection: op.collection, rkey: op.rkey)] == index
            if let cid = op.cid, isLatest, op.value == nil {
                throw ChangeFeedGap(description: "\(op.collection)/\(op.rkey) is at \(cid), but its value is missing")
            }
            // Only each record's latest op matters for its value; the rest were replaced.
            guard isLatest else { continue }
            if op.collection == Lexicon.chunks {
                continuations[op.rkey] = op.cid == nil ? nil : op.value
                continue
            }
            if op.collection == Lexicon.version {
                if let cid = op.cid {
                    history.set(drive.readVersion(id: op.rkey, cid: cid, value: op.value, continuations: continuations))
                } else {
                    history.remove(op.rkey)
                }
                continue
            }
            if op.collection == Lexicon.settings, op.rkey == Lexicon.settingsKey {
                settings = op.cid == nil ? (nil, nil) : Self.readSettings(op.value, drive: drive)
                continue
            }
            guard op.collection == Lexicon.node else { continue }
            nodes[op.rkey] = nil
            unreadable[op.rkey] = nil
            if let cid = op.cid {
                switch drive.readNode(id: op.rkey, cid: cid, value: op.value, continuations: continuations) {
                case .readable(let node): nodes[op.rkey] = node
                case .unreadable(let record): unreadable[op.rkey] = record
                }
            }
        }
        repo.revision = commit.rev
        repo.data = commit.data
        let matches = repo.check(commit)
        let mismatch = ChangeFeedGap(description: "the records don't match the drive's commit at \(commit.rev)")
        if !matches, verified { throw mismatch }
        if ops.contains(where: { $0.collection == Lexicon.node }) {
            tree = DriveTree(Array(nodes.values), unreadable: Array(unreadable.values))
        }
        self.repo = repo
        self.history = history
        self.continuations = continuations
        (self.settings, unreadableSettings) = settings
        verified = matches
        self.mismatch = matches ? nil : mismatch
    }

    /// The settings record read with `drive`, or, if it can't be, its value to read again later.
    private static func readSettings(_ value: JSONValue?, drive: Drive) -> (DriveSettings?, JSONValue?) {
        if let settings = drive.readSettings(value) { return (settings, nil) }
        return (nil, value)
    }

    private mutating func setSettings(_ value: JSONValue?, drive: Drive) {
        (settings, unreadableSettings) = Self.readSettings(value, drive: drive)
    }

    /// The keys of the `chunks` records in the drive, by the version they belong to, in order.
    /// They count as part of it: deleting it deletes them too.
    func continuationKeys() -> [String: [String]] {
        var found: [String: [(index: Int, key: String)]] = [:]
        for key in (repo.records[Lexicon.chunks] ?? [:]).keys {
            guard let (version, index) = Lexicon.continuationOwner(key) else { continue }
            found[version, default: []].append((index, key))
        }
        return found.mapValues { $0.sorted { $0.index < $1.index }.map(\.key) }
    }

    /// Reads the unreadable records again with `drive`, e.g. once a key arrives.
    public mutating func reread(with drive: Drive) {
        let continuations = continuations
        if !history.unreadable.isEmpty {
            history.reread { drive.readVersion(id: $0, cid: $1, value: $2, continuations: continuations) }
        }
        if let value = unreadableSettings { setSettings(value, drive: drive) }
        guard !tree.unreadable.isEmpty else { return }
        var nodes = tree.nodes
        var unreadable: [UnreadableNode] = []
        for record in tree.unreadable.values {
            switch drive.readNode(id: record.id, cid: record.cid, value: record.value, continuations: continuations) {
            case .readable(let node): nodes[node.id] = node
            case .unreadable(let record): unreadable.append(record)
            }
        }
        tree = DriveTree(Array(nodes.values), unreadable: unreadable)
    }

    // MARK: Saving

    /// Bumped whenever what's saved, or how records are read, changes: older saves are ignored.
    static let savedVersion = 4

    private struct Saved: Codable {
        struct SavedContinuation: Codable {
            var key: String
            var value: JSONValue
        }
        struct SavedNode: Codable {
            var id: String
            var cid: String
            var record: NodeRecord
        }
        struct SavedUnreadable: Codable {
            var id: String
            var cid: String
            var reason: UnreadableNode.Reason
            var value: JSONValue?
        }
        struct SavedVersion: Codable {
            var id: String
            var cid: String
            var record: VersionRecord
        }
        struct SavedUnreadableVersion: Codable {
            var id: String
            var cid: String
            var reason: UnreadableNode.Reason
            var value: JSONValue?
        }
        var version: Int
        var revision: String
        var data: Data?
        var listedAt: Date
        var verified: Bool
        var records: [String: [String: String]]
        /// `RepoState.hash`'s 2048-byte state, so loading doesn't hash every record again. When
        /// it's missing (or the wrong size), it's computed from `records`.
        var setHash: Data?
        var nodes: [SavedNode]
        var unreadable: [SavedUnreadable]
        var versions: [SavedVersion]
        var unreadableVersions: [SavedUnreadableVersion]
        var settings: DriveSettings?
        var unreadableSettings: JSONValue?
        var continuations: [SavedContinuation]
    }

    /// The snapshot as JSON, to pick up from after a restart. `nil` if there's no repo.
    public func saved() throws -> Data? {
        guard let revision else { return nil }
        let saved = Saved(
            version: Self.savedVersion, revision: revision, data: repo.data, listedAt: listedAt,
            verified: verified, records: repo.records, setHash: repo.hash.setHash.state,
            nodes: tree.nodes.values.sorted { $0.id < $1.id }.map { .init(id: $0.id, cid: $0.cid, record: $0.record) },
            unreadable: tree.unreadable.values.sorted { $0.id < $1.id }.map {
                .init(id: $0.id, cid: $0.cid, reason: $0.reason, value: $0.value)
            },
            versions: history.versions.values.sorted { $0.id < $1.id }.map {
                .init(id: $0.id, cid: $0.cid, record: $0.record)
            },
            unreadableVersions: history.unreadable.values.sorted { $0.id < $1.id }.map {
                .init(id: $0.id, cid: $0.cid, reason: $0.reason, value: $0.value)
            },
            settings: settings, unreadableSettings: unreadableSettings,
            continuations: continuations.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(saved)
    }

    /// A snapshot saved by `saved()`. Its unreadable records are read again with `drive` (which
    /// may be newer than the one that saved it). It isn't trusted until it has been listed
    /// again or checked (`needsFullListing`): a verified one is checked against the commit on its
    /// first update, and listed again only if that fails.
    public init?(saved data: Data, drive: Drive) {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.savedVersion,
            saved.nodes.count == saved.records[Lexicon.node, default: [:]].count - saved.unreadable.count,
            saved.versions.count + saved.unreadableVersions.count
                == saved.records[Lexicon.version, default: [:]].count,
            saved.continuations.count <= saved.records[Lexicon.chunks, default: [:]].count
        else { return nil }
        continuations = Dictionary(saved.continuations.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        history = DriveHistory(
            saved.versions.map { Version(id: $0.id, cid: $0.cid, record: $0.record) },
            unreadable: saved.unreadableVersions.map {
                .init(id: $0.id, cid: $0.cid, reason: $0.reason, value: $0.value)
            })
        settings = saved.settings
        unreadableSettings = saved.unreadableSettings
        repo = RepoState(
            revision: saved.revision, data: saved.data, records: saved.records,
            hash: saved.setHash.flatMap(LtHash.init(state:)).map { RepoSetHash(setHash: $0) })
        tree = DriveTree(
            saved.nodes.map { Node(id: $0.id, cid: $0.cid, record: $0.record) },
            unreadable: saved.unreadable.map { .init(id: $0.id, cid: $0.cid, reason: $0.reason, value: $0.value) })
        listedAt = saved.listedAt
        listedThisRun = false
        verified = saved.verified
        reread(with: drive)
    }
}

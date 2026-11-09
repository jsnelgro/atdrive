import Foundation

/// Every record in the drive's repo, in every collection (collection → rkey → CID), at a
/// revision. Full listings and the change feed both keep it current, so it's the one place to
/// check what we hold against the drive's commit (`check`).
public struct RepoState: Sendable, Equatable {
    public internal(set) var revision: String?
    /// The commit's `data` at `revision` (see `RepoCommit`).
    public internal(set) var data: Data?
    public internal(set) var records: [String: [String: String]] = [:]

    public init(revision: String? = nil, data: Data? = nil, records: [String: [String: String]] = [:]) {
        self.revision = revision
        self.data = data
        self.records = records
    }

    public func cid(_ collection: String, _ rkey: String) -> String? { records[collection]?[rkey] }

    mutating func set(_ collection: String, _ rkey: String, cid: String?) {
        records[collection, default: [:]][rkey] = cid
        if records[collection]?.isEmpty == true { records[collection] = nil }
    }

    /// Whether these are exactly the records the commit covers: an LtHash over
    /// `collection/rkey/cid` for every record, compared with `commit.data`. That catches
    /// anything a compacted change feed hid. `nil` while it can't be checked (there's no LtHash
    /// here yet); `Drive.update` then lists the whole drive at start and every hour instead.
    public func check(_ commit: RepoCommit) -> Bool? { nil }
}

/// The change feed doesn't connect to what we hold: an op's `prev` isn't the CID we have, a
/// current value is missing, the revision moved without ops, or the records don't match the
/// commit. The fix is a full listing.
public struct ChangeFeedGap: Error, CustomStringConvertible, Equatable {
    public var description: String
}

/// The drive as this device last fetched it: every record's CID (`repo`) and the file tree
/// (`tree`, with the node records it can't read). `Drive.update` keeps it current by applying
/// the change feed, and lists everything again when that can't be trusted.
public struct DriveSnapshot: Sendable {
    public private(set) var repo: RepoState
    public private(set) var tree: DriveTree
    /// When the whole drive was last listed.
    public private(set) var listedAt: Date
    /// Whether that listing happened in this process. A saved snapshot is listed again when
    /// first used, unless it was checked against the commit (`RepoState.check`).
    public private(set) var listedThisRun: Bool
    /// Whether the records were checked against the latest commit and matched. Then every
    /// update is checked too (a mismatch is a gap), so no periodic listing is needed.
    public private(set) var verified = false

    /// How often the whole drive is listed while snapshots can't be checked exactly.
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

    /// A full listing (every collection) taken after `commit`, so at least as new as it.
    init(
        listing: [(collection: String, rkey: String, cid: String, value: JSONValue?)], commit: RepoCommit,
        listedAt: Date, read: (String, String, JSONValue?) -> NodeEntry
    ) {
        var repo = RepoState(revision: commit.rev, data: commit.data)
        var entries: [NodeEntry] = []
        for record in listing {
            repo.set(record.collection, record.rkey, cid: record.cid)
            if record.collection == Lexicon.node { entries.append(read(record.rkey, record.cid, record.value)) }
        }
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

    /// Applies the change feed since `revision`. Nothing changes if it throws.
    ///
    /// `strict` checks that each op's `prev` is the CID we hold: off only when catching up on a
    /// listing, which may already include some of the ops. Either way, an op whose value is
    /// missing though nothing later replaced it, or a revision that moved without ops, is a gap.
    mutating func apply(_ changes: DriveChanges, strict: Bool, read: (String, String, JSONValue?) -> NodeEntry)
        throws
    {
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
        for (index, op) in ops.enumerated() {
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
            guard op.collection == Lexicon.node, isLatest else { continue }
            nodes[op.rkey] = nil
            unreadable[op.rkey] = nil
            if let cid = op.cid {
                switch read(op.rkey, cid, op.value) {
                case .readable(let node): nodes[op.rkey] = node
                case .unreadable(let record): unreadable[op.rkey] = record
                }
            }
        }
        repo.revision = commit.rev
        repo.data = commit.data
        var verified = false
        if let matches = repo.check(commit) {
            guard matches else { throw ChangeFeedGap(description: "the records don't match the drive's commit") }
            verified = true
        }
        if ops.contains(where: { $0.collection == Lexicon.node }) {
            tree = DriveTree(Array(nodes.values), unreadable: Array(unreadable.values))
        }
        self.repo = repo
        self.verified = verified
    }

    /// Reads the unreadable records again (with `Drive.readNode`), e.g. once a key arrives.
    public mutating func reread(_ read: (String, String, JSONValue?) -> NodeEntry) {
        guard !tree.unreadable.isEmpty else { return }
        var nodes = tree.nodes
        var unreadable: [UnreadableNode] = []
        for record in tree.unreadable.values {
            switch read(record.id, record.cid, record.value) {
            case .readable(let node): nodes[node.id] = node
            case .unreadable(let record): unreadable.append(record)
            }
        }
        tree = DriveTree(Array(nodes.values), unreadable: unreadable)
    }

    // MARK: Saving

    /// Bumped whenever what's saved, or how records are read, changes: older saves are ignored.
    static let savedVersion = 1

    private struct Saved: Codable {
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
        var version: Int
        var revision: String
        var data: Data?
        var listedAt: Date
        var verified: Bool
        var records: [String: [String: String]]
        var nodes: [SavedNode]
        var unreadable: [SavedUnreadable]
    }

    /// The snapshot as JSON, to pick up from after a restart. `nil` if there's no repo.
    public func saved() throws -> Data? {
        guard let revision else { return nil }
        let saved = Saved(
            version: Self.savedVersion, revision: revision, data: repo.data, listedAt: listedAt,
            verified: verified, records: repo.records,
            nodes: tree.nodes.values.sorted { $0.id < $1.id }.map { .init(id: $0.id, cid: $0.cid, record: $0.record) },
            unreadable: tree.unreadable.values.sorted { $0.id < $1.id }.map {
                .init(id: $0.id, cid: $0.cid, reason: $0.reason, value: $0.value)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(saved)
    }

    /// A snapshot saved by `saved()`. Its unreadable records are read again with `drive` (which
    /// may be newer than the one that saved it). It isn't trusted until it has been listed
    /// again or checked (`needsFullListing`).
    public init?(saved data: Data, drive: Drive) {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.savedVersion,
            saved.nodes.count == saved.records[Lexicon.node, default: [:]].count - saved.unreadable.count
        else { return nil }
        repo = RepoState(revision: saved.revision, data: saved.data, records: saved.records)
        tree = DriveTree(
            saved.nodes.map { Node(id: $0.id, cid: $0.cid, record: $0.record) },
            unreadable: saved.unreadable.map { .init(id: $0.id, cid: $0.cid, reason: $0.reason, value: $0.value) })
        listedAt = saved.listedAt
        listedThisRun = false
        verified = saved.verified
        reread(drive.readNode)
    }
}

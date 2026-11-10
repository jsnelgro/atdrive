/// A file or folder as stored in the drive.
public struct Node: Sendable, Identifiable, Equatable {
    /// Record key: permanent, survives renames and moves.
    public let id: String
    /// Content identifier of the current record version.
    public let cid: String
    public let record: NodeRecord

    public init(id: String, cid: String, record: NodeRecord) {
        self.id = id
        self.cid = cid
        self.record = record
    }

    public var name: String { record.name }
    public var isFolder: Bool { record.kind == .folder }
}

/// A node record that exists in the drive but that this device can't read (yet). It must never
/// be mistaken for a deletion: sync and the Mac extension leave it, and its local copy, alone.
public struct UnreadableNode: Sendable, Equatable {
    /// Why a record (a node, or a version) can't be read.
    public enum Reason: String, Sendable, Equatable, Codable, CustomStringConvertible {
        /// It doesn't decode: written by a newer version of ATDrive.
        case newerFormat
        /// Its name couldn't be used in a folder (e.g. `..`). Our own writes never do this.
        case invalidName
        /// Sealed with a drive key this device doesn't have: one newer than its keyring (another
        /// device rotated it), or any at all, before this device is unlocked.
        case missingKey
        /// Sealed, but it doesn't open: changed on the server, or moved there from another record.
        case tampered

        public var description: String {
            switch self {
            case .newerFormat: "it was written by a newer version of ATDrive"
            case .invalidName: "its name can't be used in a folder"
            case .missingKey: "it's sealed with a drive key this device doesn't have (yet)"
            case .tampered: "it doesn't decrypt: it was changed on the server, or isn't where it was written"
            }
        }
    }

    public let id: String
    public let cid: String
    public let reason: Reason
    /// The record as stored, so it can be read again later (e.g. by a newer version).
    public let value: JSONValue?

    public init(id: String, cid: String, reason: Reason, value: JSONValue?) {
        self.id = id
        self.cid = cid
        self.reason = reason
        self.value = value
    }
}

/// A node record as read from the drive: a `Node`, or one this device can't read.
public enum NodeEntry: Sendable, Equatable {
    case readable(Node)
    case unreadable(UnreadableNode)

    public var id: String {
        switch self {
        case .readable(let node): node.id
        case .unreadable(let record): record.id
        }
    }
}

/// A slash-separated location in a drive, always from the top: `/photos/2026/cat.jpg`.
public struct DrivePath: Sendable, Equatable, CustomStringConvertible {
    public let components: [String]

    public static let root = DrivePath(components: [])

    public init(_ string: String) {
        var components: [String] = []
        for part in string.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(part))
            }
        }
        self.components = components
    }

    init(components: [String]) { self.components = components }

    public var isRoot: Bool { components.isEmpty }
    public var name: String? { components.last }
    public var parent: DrivePath { DrivePath(components: components.dropLast()) }
    public func appending(_ name: String) -> DrivePath { DrivePath(components: components + [name]) }
    public var description: String { "/" + components.joined(separator: "/") }

    /// Names can be anything a filesystem allows, except empty, `.`, `..`, or containing `/`.
    public static func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
            name.utf8.count <= 255
        else { throw ATDriveError.invalidName(name) }
    }
}

/// The whole drive in memory, indexed for path lookups.
///
/// Concurrent edits from different devices can leave a node whose parent was deleted, or two
/// folders moved into each other. Rather than hide those, they're shown at the top level.
///
/// Records this device can't read are kept apart (`unreadable`): they exist, so they're never
/// treated as deleted. Whatever is inside one stays there (it isn't lifted to the top), but it
/// can't be reached by path, since the unreadable record's name and place are unknown.
public struct DriveTree: Sendable {
    public private(set) var nodes: [String: Node]
    /// Node records that exist but can't be read here, by ID.
    public private(set) var unreadable: [String: UnreadableNode]
    /// Folder ID → children; the `nil` key is the top level.
    private var children: [String?: [Node]]
    private var parents: [String: String?]
    /// Nodes inside an unreadable record (at any depth) → that record.
    private var hidden: [String: String]

    public init(_ nodes: [Node], unreadable: [UnreadableNode] = []) {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unreadable = Dictionary(
            unreadable.filter { byID[$0.id] == nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [String: String?] = [:]
        for node in byID.values {
            let parent = node.record.parent
            let parentIsFolder = parent.flatMap { byID[$0] }?.isFolder ?? false
            // Inside something unreadable: it may well be a folder, so it stays there.
            let parentIsUnreadable = parent.map { unreadable[$0] != nil } ?? false
            parents[node.id] = .some(parentIsFolder || parentIsUnreadable ? parent : nil)
        }
        // Anything that can't reach the top (a cycle of moves) is re-attached there.
        var reachable = Set<String>()
        var hidden: [String: String] = [:]
        var childIDs: [String?: [String]] = [:]
        for (id, parent) in parents { childIDs[parent, default: []].append(id) }
        func visit(_ parent: String?, under unreadableRoot: String? = nil) {
            var stack = childIDs[parent] ?? []
            while let id = stack.popLast() {
                guard reachable.insert(id).inserted else { continue }
                if let unreadableRoot { hidden[id] = unreadableRoot }
                stack += childIDs[id] ?? []
            }
        }
        visit(nil)
        for id in unreadable.keys.sorted() { visit(id, under: id) }
        for id in parents.keys.sorted() where !reachable.contains(id) {
            parents[id] = .some(nil)
            visit(id)
            reachable.insert(id)
        }
        var children: [String?: [Node]] = [:]
        for (id, parent) in parents { children[parent, default: []].append(byID[id]!) }
        for key in children.keys { children[key]!.sort(by: Self.displayOrder) }
        self.nodes = byID
        self.unreadable = unreadable
        self.parents = parents
        self.children = children
        self.hidden = hidden
    }

    public init(_ entries: [NodeEntry]) {
        var nodes: [Node] = []
        var unreadable: [UnreadableNode] = []
        for entry in entries {
            switch entry {
            case .readable(let node): nodes.append(node)
            case .unreadable(let record): unreadable.append(record)
            }
        }
        self.init(nodes, unreadable: unreadable)
    }

    /// The unreadable record a node is inside, at any depth, if any. Such a node can't be shown
    /// in its place, so listings leave it out, and sync leaves it where it was.
    public func unreadableContainer(of id: String) -> String? { hidden[id] }

    /// Folders first, then by name (case-insensitive), then oldest first.
    static func displayOrder(_ a: Node, _ b: Node) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        let order = a.name.lowercased().compare(b.name.lowercased())
        if order != .orderedSame { return order == .orderedAscending }
        return a.id < b.id
    }

    /// Children of a folder (`nil` for the top level).
    public func children(of folder: String?) -> [Node] { children[folder] ?? [] }

    public func child(named name: String, in folder: String?) -> Node? {
        children(of: folder).first { $0.name == name }
    }

    public enum Location: Sendable, Equatable {
        case root
        case node(Node)
        case missing
    }

    /// What's at a path. Throws if the path goes *through* a file (`/notes.txt/x`).
    public func find(_ path: DrivePath) throws -> Location {
        var current: Node? = nil
        for (index, name) in path.components.enumerated() {
            if let current, !current.isFolder {
                throw ATDriveError.notAFolder(DrivePath(components: Array(path.components[..<index])).description)
            }
            guard let next = child(named: name, in: current?.id) else { return .missing }
            current = next
        }
        return current.map(Location.node) ?? .root
    }

    /// The node at a path (`nil` for the top level). Throws if nothing is there.
    public func locate(_ path: DrivePath) throws -> Node? {
        switch try find(path) {
        case .root: nil
        case .node(let node): node
        case .missing: throw ATDriveError.notFound(path.description)
        }
    }

    /// The folder a node is shown in (`nil` for the top level). Usually `record.parent`, except
    /// for nodes lifted to the top because their folder is gone (see the type's doc comment).
    public func parent(of id: String) -> String? {
        parents[id] ?? nil
    }

    /// What changed between `old` and this tree: nodes that are new, edited, or shown in a
    /// different folder, and the IDs of nodes that no longer exist.
    ///
    /// Nothing unreadable counts as deleted, and nothing inside an unreadable record counts as
    /// changed: both stay as they were last seen until they can be read again.
    public func changes(since old: DriveTree) -> (updated: [Node], deleted: [String]) {
        let updated = nodes.values.filter { node in
            guard hidden[node.id] == nil else { return false }
            guard let before = old.nodes[node.id], old.hidden[node.id] == nil else { return true }
            return before.cid != node.cid || old.parent(of: node.id) != parent(of: node.id)
        }
        let gone = { (id: String) in nodes[id] == nil && unreadable[id] == nil }
        let deleted = old.nodes.keys.filter(gone) + old.unreadable.keys.filter(gone)
        return (updated.sorted { $0.id < $1.id }, deleted.sorted())
    }

    /// Where a node is shown. For one inside an unreadable record, the path from inside it.
    public func path(of node: Node) -> DrivePath {
        var components = [node.name]
        var parent = parents[node.id] ?? nil
        while let id = parent, let folder = nodes[id] {
            components.append(folder.name)
            parent = parents[id] ?? nil
        }
        return DrivePath(components: components.reversed())
    }

    /// Everything inside a folder, at any depth, deepest first (safe deletion order).
    public func descendants(of folder: String) -> [Node] {
        var result: [(Node, Int)] = []
        var stack: [(String, Int)] = [(folder, 1)]
        while let (id, depth) = stack.popLast() {
            for child in children(of: id) {
                result.append((child, depth))
                if child.isFolder { stack.append((child.id, depth + 1)) }
            }
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Whether `node` is `folder` or somewhere inside it.
    public func isInside(_ node: String, folder: String) -> Bool {
        var current: String? = node
        while let id = current {
            if id == folder { return true }
            current = parents[id] ?? nil
        }
        return false
    }
}

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
public struct DriveTree: Sendable {
    public private(set) var nodes: [String: Node]
    /// Folder ID → children; the `nil` key is the top level.
    private var children: [String?: [Node]]
    private var parents: [String: String?]

    public init(_ nodes: [Node]) {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [String: String?] = [:]
        for node in byID.values {
            let parent = node.record.parent
            let parentIsFolder = parent.flatMap { byID[$0] }?.isFolder ?? false
            parents[node.id] = .some(parentIsFolder ? parent : nil)
        }
        // Anything that can't reach the top (a cycle of moves) is re-attached there.
        var reachable = Set<String>()
        var childIDs: [String?: [String]] = [:]
        for (id, parent) in parents { childIDs[parent, default: []].append(id) }
        func visit(_ parent: String?) {
            var stack = childIDs[parent] ?? []
            while let id = stack.popLast() {
                guard reachable.insert(id).inserted else { continue }
                stack += childIDs[id] ?? []
            }
        }
        visit(nil)
        for id in parents.keys.sorted() where !reachable.contains(id) {
            parents[id] = .some(nil)
            visit(id)
            reachable.insert(id)
        }
        var children: [String?: [Node]] = [:]
        for (id, parent) in parents { children[parent, default: []].append(byID[id]!) }
        for key in children.keys { children[key]!.sort(by: Self.displayOrder) }
        self.nodes = byID
        self.parents = parents
        self.children = children
    }

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

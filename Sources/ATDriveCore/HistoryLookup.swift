import Foundation

/// Finding things by path for commands that work on history: in the drive as it is, or, for
/// something deleted, in the trash, where it was when it was deleted.
extension DriveSnapshot {
    /// What a path names, now or in the trash.
    public enum Found: Sendable, Equatable {
        /// The top of the drive.
        case root
        /// Something in the drive now.
        case node(Node)
        /// Nothing is there now, but something deleted from there is in the trash.
        case trashed(DriveHistory.TrashItem)

        /// The node's ID; `nil` for the top of the drive.
        public var id: String? {
            switch self {
            case .root: nil
            case .node(let node): node.id
            case .trashed(let item): item.id
            }
        }

        public var isFolder: Bool {
            switch self {
            case .root: true
            case .node(let node): node.isFolder
            case .trashed(let item): item.isFolder
            }
        }
    }

    /// What's at `path` now, or else what was last deleted from there, if it's still in the
    /// trash. Throws `notFound` if neither.
    public func find(_ path: DrivePath, now: Date = Date()) throws -> Found {
        let location: DriveTree.Location
        do {
            location = try tree.find(path)
        } catch {
            // It goes through a file now, but may have been in a folder of that name then.
            if let item = trashed(at: path, now: now) { return .trashed(item) }
            throw error
        }
        switch location {
        case .root: return .root
        case .node(let node): return .node(node)
        case .missing:
            if let item = trashed(at: path, now: now) { return .trashed(item) }
            throw ATDriveError.notFound(path.description)
        }
    }

    /// What was deleted from `path` and is still in the trash: the latest, if several were.
    /// That includes things deleted along with their folder.
    public func trashed(at path: DrivePath, now: Date = Date()) -> DriveHistory.TrashItem? {
        trash(now: now).first { $0.path == path }
    }

    /// A trash item and everything deleted with it (for a folder, what was in it), folders
    /// before what's in them: what restoring or purging it brings back or deletes.
    public func deletedTogether(_ item: DriveHistory.TrashItem, now: Date = Date()) -> [DriveHistory.TrashItem] {
        let trash = Dictionary(trash(now: now).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return history.deletedTogether(item.id, trash: trash)
    }
}

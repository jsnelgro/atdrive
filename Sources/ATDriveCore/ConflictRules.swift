import Foundation

/// How ATDrive settles something that changed in two places. The synced folder (`SyncPlan`) and
/// the Mac app (the File Provider extension) both decide with these, so a change ends up the same
/// whichever kind of device it was made on.
///
/// Each rule compares the version both sides last agreed on (`base`) with this device's (`local`)
/// and the drive's (`remote`):
///
/// - **Contents:** a change on one side wins. Changed on both sides, differently: the drive's
///   version keeps the name, and this device's is saved beside it as a conflicted copy
///   (`ConflictName`). Changed on both sides the same way: nothing to do.
/// - **Folder and name:** a move or rename on one side wins. Moved on both sides: the drive's
///   move wins.
/// - **Deleted on one side:** deleted on the other too, unless its contents changed there since;
///   then it's kept. Being moved or renamed there doesn't keep it.
/// - **A deleted folder** is kept if anything kept is inside it: something added to it, moved
///   into it, or edited in it since the deleting side last saw it. The rest of it goes.
/// - **Two different things with one name:** the one arriving second is renamed to a conflicted
///   copy. Two identical things (two folders, or two files with the same contents) are treated
///   as one.
public enum ConflictRules {
    public enum Contents: Sendable, Equatable {
        /// The drive's version stands: nothing new here, or both sides have the same.
        case remote
        /// This device's version replaces the drive's.
        case local
        /// Both changed, differently: the drive's version keeps the name, and this device's
        /// becomes a conflicted copy beside it.
        case conflict
    }

    /// A file's contents, compared by hash.
    public static func contents(base: String?, local: String?, remote: String?) -> Contents {
        if local == remote || local == base { return .remote }
        return remote == base ? .local : .conflict
    }

    /// Where something ends up (its folder and name) when it may have moved on both sides.
    public static func location<Location: Equatable>(base: Location, local: Location, remote: Location)
        -> Location
    {
        local == base || remote != base ? remote : local
    }

    /// Whether deleting a file on one side deletes it on the other, given its contents (hash)
    /// when the deleting side last saw it, and on the other side now.
    public static func deleteStands(base: String?, other: String?) -> Bool { base == other }

    /// What's kept (node IDs) when `folder` is deleted on a device that last saw the drive as
    /// `seen`: anything added to it, moved into it or edited in it since, and the folders that
    /// lead to those, `folder` included. Empty if the whole folder goes.
    public static func keptWhenDeleting(folder: String, now: DriveTree, seen: DriveTree) -> Set<String> {
        var kept: Set<String> = []
        for node in now.descendants(of: folder) {
            let before = seen.nodes[node.id]
            let arrived = before == nil || !seen.isInside(node.id, folder: folder)
            let edited =
                !node.isFolder
                && before.map { !deleteStands(base: $0.record.sha256, other: node.record.sha256) }
                    ?? false
            guard arrived || edited else { continue }
            var current: String? = node.id
            while let id = current, kept.insert(id).inserted, id != folder {
                current = now.parent(of: id)
            }
        }
        if !kept.isEmpty { kept.insert(folder) }
        return kept
    }
}

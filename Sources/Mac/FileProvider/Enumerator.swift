import ATDriveCore
import FileProvider
import Foundation

/// Lists what's in a folder (or the whole drive, for the working set) and reports what
/// changed since a sync anchor.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    enum Scope {
        /// Everything in the drive: how the system learns about changes in the background.
        case workingSet
        /// A folder's direct children (`nil` = top level), or just the item if it's a file.
        case container(String?)
    }

    private let scope: Scope
    private let index: DriveIndex

    init(scope: Scope, index: DriveIndex) {
        self.scope = scope
        self.index = index
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let tree = try await index.refresh().tree
                let items = try listing(in: tree)
                for start in stride(from: 0, to: items.count, by: 200) {
                    observer.didEnumerate(Array(items[start..<min(start + 200, items.count)]))
                }
                observer.finishEnumerating(upTo: nil)
                if case .workingSet = scope { await index.markSeen(tree) }
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                try await reportChanges(to: observer, since: anchor)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    private func reportChanges(to observer: NSFileProviderChangeObserver, since anchor: NSFileProviderSyncAnchor)
        async throws
    {
        let (revision, tree) = try await index.refresh()
        var isWorkingSet = false
        // Things a delete here left on the drive (see deleteItem): reported so they come back.
        var resend: Set<String> = []
        if case .workingSet = scope {
            isWorkingSet = true
            resend = await index.takeResend()
        }
        var updated: [Node] = []
        var deleted: [String] = []
        if revision != anchor.revision {
            // The system has had the drive, which is now gone: not reported as emptied (that
            // would delete everything here), nor re-listed as empty (the same).
            if revision == DriveIndex.emptyRevision { throw NSFileProviderError(.serverUnreachable) }
            // Too old to diff against (e.g. the extension restarted): the system re-lists instead.
            guard let old = await index.tree(at: anchor.revision) else {
                throw NSFileProviderError(.syncAnchorExpired)
            }
            let changes = tree.changes(since: old)
            updated = changes.updated.filter { isInScope($0.id, in: tree) || isInScope($0.id, in: old) }
            deleted = changes.deleted.filter { isInScope($0, in: old) }
        }
        let alreadyUpdated = Set(updated.map(\.id))
        updated += resend.subtracting(alreadyUpdated).compactMap { tree.nodes[$0] }
            .sorted { tree.path(of: $0).components.count < tree.path(of: $1).components.count }
        if !updated.isEmpty { observer.didUpdate(updated.map { Item($0, in: tree) }) }
        if !deleted.isEmpty {
            observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) })
        }
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(revision: revision), moreComing: false)
        if isWorkingSet { await index.markSeen(tree) }
    }

    func currentSyncAnchor(completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let revision = try? await index.refresh().revision
            completionHandler(revision.map(NSFileProviderSyncAnchor.init(revision:)))
        }
    }

    private func listing(in tree: DriveTree) throws -> [Item] {
        switch scope {
        case .workingSet:
            // Not what's inside a record this Mac can't read: it can't be placed.
            return tree.nodes.values.filter { tree.unreadableContainer(of: $0.id) == nil }.map { Item($0, in: tree) }
        case .container(nil):
            return tree.children(of: nil).map { Item($0, in: tree) }
        case .container(let id?):
            guard let node = tree.nodes[id] else {
                // A folder this Mac could read before but can't now: it's still there, and so is
                // what's inside it.
                if tree.unreadable[id] != nil { return tree.children(of: id).map { Item($0, in: tree) } }
                throw NSFileProviderError(.noSuchItem)
            }
            return node.isFolder ? tree.children(of: id).map { Item($0, in: tree) } : [Item(node, in: tree)]
        }
    }

    /// Whether a node belongs to what this enumerator covers, in a given tree.
    private func isInScope(_ id: String, in tree: DriveTree) -> Bool {
        if tree.nodes[id] == nil {
            // Unreadable in that tree (and since deleted): only the working set covers it, as
            // its folder isn't known.
            guard tree.unreadable[id] != nil, case .workingSet = scope else { return false }
            return true
        }
        switch scope {
        case .workingSet: return true
        case .container(let container):
            return id == container || tree.parent(of: id) == container
        }
    }
}

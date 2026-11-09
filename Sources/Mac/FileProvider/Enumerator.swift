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
                let items = try items(in: tree)
                for start in stride(from: 0, to: items.count, by: 200) {
                    observer.didEnumerate(Array(items[start..<min(start + 200, items.count)]))
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let (revision, tree) = try await index.refresh()
                if revision == anchor.revision {
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                }
                // Too old to diff against (e.g. the extension restarted): the system re-lists.
                guard let old = await index.tree(at: anchor.revision) else {
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                let changes = tree.changes(since: old)
                let updated = changes.updated.filter { isInScope($0.id, in: tree) || isInScope($0.id, in: old) }
                let deleted = changes.deleted.filter { isInScope($0, in: old) }
                if !updated.isEmpty { observer.didUpdate(updated.map { Item($0, in: tree) }) }
                if !deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deleted.map(NSFileProviderItemIdentifier.init))
                }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(revision: revision), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let revision = try? await index.refresh().revision
            completionHandler(revision.map(NSFileProviderSyncAnchor.init(revision:)))
        }
    }

    private func items(in tree: DriveTree) throws -> [Item] {
        switch scope {
        case .workingSet:
            return tree.nodes.values.map { Item($0, in: tree) }
        case .container(nil):
            return tree.children(of: nil).map { Item($0, in: tree) }
        case .container(let id?):
            guard let node = tree.nodes[id] else { throw NSFileProviderError(.noSuchItem) }
            return node.isFolder ? tree.children(of: id).map { Item($0, in: tree) } : [Item(node, in: tree)]
        }
    }

    /// Whether a node belongs to what this enumerator covers, in a given tree.
    private func isInScope(_ id: String, in tree: DriveTree) -> Bool {
        guard tree.nodes[id] != nil else { return false }
        switch scope {
        case .workingSet: return true
        case .container(let container):
            return id == container || tree.parent(of: id) == container
        }
    }
}

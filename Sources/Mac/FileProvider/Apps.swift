import ATDriveCore
import ATDriveMacSupport
import FileProvider
import Foundation
import UniformTypeIdentifiers

// The ATDrive Apps location (`AppsDomain`): the apps view (`AppData`) in Finder, read-only. The
// same extension serves it, as a second domain; none of the drive's sync or conflict code is
// involved. Items are the apps view's tree (`AppTree`); its anchor (which changes whenever
// anything in it does) is the sync anchor.

/// The extension's view of the apps: the latest tree, and the last few by anchor so enumerators
/// can say what changed since one.
actor AppsIndex {
    private var data: AppData?
    private var snapshot: AppDataSnapshot?
    private var current: (anchor: String, tree: AppTree, spotlight: Bool, at: Date)?
    private var history: [(anchor: String, tree: AppTree)] = []
    private var refreshing: Task<AppDataSnapshot, Error>?
    private let historyLimit = 16
    /// Reading everything again costs a request or two per space: requests that come together
    /// (Finder asking for an item, then its folder) share one.
    private let reuseFor: TimeInterval = 5

    func apps() async throws -> AppData {
        if let data { return data }
        let drive = try await DriveIndex.openHome()
        let made = AppData(home: drive, access: SpaceAccess(ownClient: drive.client, resolver: IdentityResolver()))
        data = made
        return made
    }

    /// The apps view as it is now, read again unless it was just read.
    func refresh() async throws -> (anchor: String, tree: AppTree, spotlight: Bool) {
        if let current, Date().timeIntervalSince(current.at) < reuseFor {
            return (current.anchor, current.tree, current.spotlight)
        }
        let task: Task<AppDataSnapshot, Error>
        if let refreshing {
            task = refreshing
        } else {
            let apps = try await apps()
            let previous = snapshot
            task = Task { try await apps.update(previous) }
            refreshing = task
        }
        defer { refreshing = nil }
        let updated = try await task.value
        snapshot = updated
        let tree = updated.tree
        // Turning Spotlight on or off changes every item (`AppsItem.extendedAttributes`).
        let spotlight = AppsDomain.spotlight
        let anchor = tree.anchor + (spotlight ? ".indexed" : "")
        current = (anchor, tree, spotlight, Date())
        if history.last?.anchor != anchor {
            history.removeAll { $0.anchor == anchor }
            history.append((anchor, tree))
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }
        return (anchor, tree, spotlight)
    }

    func tree(at anchor: String) -> AppTree? {
        history.last { $0.anchor == anchor }?.tree
    }

    func contents(of item: AppTree.Item) async throws -> Data {
        try await apps().contents(of: item)
    }
}

/// An item of the apps view, as the File Provider framework sees it: read-only.
final class AppsItem: NSObject, NSFileProviderItem {
    private let item: AppTree.Item?
    private let spotlight: Bool

    /// `nil`: the top.
    init(_ item: AppTree.Item?, spotlight: Bool) {
        self.item = item
        self.spotlight = spotlight
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        item.map { NSFileProviderItemIdentifier($0.id) } ?? .rootContainer
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        item?.parent.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
    }

    var filename: String { item?.name ?? "Apps" }

    var contentType: UTType {
        guard let item else { return .folder }
        switch item.content {
        case .folder: return .folder
        case .record: return .json
        case .note: return .plainText
        case .blob: return UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        }
    }

    /// Reading only: nothing here can be changed, moved, renamed or deleted.
    var capabilities: NSFileProviderItemCapabilities {
        item?.isFolder == false ? [.allowsReading] : [.allowsReading, .allowsContentEnumerating]
    }

    var documentSize: NSNumber? { item?.size.map { NSNumber(value: $0) } }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data((item?.contentVersion ?? "top").utf8),
            metadataVersion: Data("\(item?.parent ?? "")\t\(filename)\t\(spotlight)".utf8))
    }

    /// Kept out of Spotlight's results unless `apps.spotlight` is on: the deprecated, but still
    /// honoured, `kMDItemSupportFileType = MDSystemFile`, as system files have.
    var extendedAttributes: [String: Data] {
        spotlight ? [:] : Self.hiddenFromSpotlight
    }

    static let hiddenFromSpotlight: [String: Data] = {
        guard
            let value = try? PropertyListSerialization.data(
                fromPropertyList: ["MDSystemFile"], format: .binary, options: 0)
        else { return [:] }
        return ["com.apple.metadata:kMDItemSupportFileType": value]
    }()
}

/// Lists a folder of the apps view (or all of it, for the working set) and what changed in it.
final class AppsEnumerator: NSObject, NSFileProviderEnumerator {
    /// `nil` for the working set; else the folder (`.rootContainer` for the top).
    private let container: NSFileProviderItemIdentifier?
    private let index: AppsIndex

    init(container: NSFileProviderItemIdentifier?, index: AppsIndex) {
        self.container = container
        self.index = index
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let (_, tree, spotlight) = try await index.refresh()
                let items = try listing(in: tree).map { AppsItem($0, spotlight: spotlight) }
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
                let (current, tree, spotlight) = try await index.refresh()
                if current != anchor.revision {
                    guard let old = await index.tree(at: anchor.revision) else {
                        throw NSFileProviderError(.syncAnchorExpired)
                    }
                    var updated: [AppTree.Item]
                    let changes = tree.changes(since: old)
                    if anchor.revision.hasSuffix(".indexed") != spotlight {
                        // Spotlight was turned on or off: every item's attributes changed.
                        updated = tree.descendants(of: nil)
                    } else {
                        updated = changes.updated
                    }
                    updated = updated.filter { isInScope($0.id, in: tree) }
                    let deleted = changes.deleted.filter { isInScope($0, in: old) }
                    if !updated.isEmpty { observer.didUpdate(updated.map { AppsItem($0, spotlight: spotlight) }) }
                    if !deleted.isEmpty {
                        observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) })
                    }
                }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(revision: current), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let anchor = try? await index.refresh().anchor
            completionHandler(anchor.map(NSFileProviderSyncAnchor.init(revision:)))
        }
    }

    private var folderID: String? {
        guard let container, container != .rootContainer else { return nil }
        return container.rawValue
    }

    private func listing(in tree: AppTree) throws -> [AppTree.Item] {
        guard let container else { return tree.descendants(of: nil) }
        guard let id = folderID else { return tree.children(of: nil) }
        guard let item = tree.items[id] else { throw NSFileProviderError(.noSuchItem) }
        return item.isFolder ? tree.children(of: id) : [item]
    }

    private func isInScope(_ id: String, in tree: AppTree) -> Bool {
        guard container != nil else { return true }
        return id == folderID || tree.items[id]?.parent == folderID
    }
}

/// The extension's work for the apps domain: reading only.
final class AppsProvider {
    let index = AppsIndex()
    private let domain: NSFileProviderDomain

    init(domain: NSFileProviderDomain) {
        self.domain = domain
    }

    func item(
        for identifier: NSFileProviderItemIdentifier, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        Task {
            do {
                let (_, tree, spotlight) = try await index.refresh()
                if identifier == .rootContainer { return completionHandler(AppsItem(nil, spotlight: spotlight), nil) }
                guard let item = tree.items[identifier.rawValue] else { throw NSFileProviderError(.noSuchItem) }
                completionHandler(AppsItem(item, spotlight: spotlight), nil)
            } catch {
                completionHandler(nil, FileProviderErrors.map(error))
            }
        }
    }

    func enumerator(for container: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        switch container {
        case .workingSet: return AppsEnumerator(container: nil, index: index)
        case .trashContainer: throw CocoaError(.featureUnsupported)
        default: return AppsEnumerator(container: container, index: index)
        }
    }

    func fetchContents(
        for identifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            do {
                let (_, tree, spotlight) = try await index.refresh()
                guard let item = tree.items[identifier.rawValue], !item.isFolder else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let data = try await index.contents(of: item)
                guard let manager = NSFileProviderManager(for: domain) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                let url = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                try data.write(to: url)
                completionHandler(url, AppsItem(item, spotlight: spotlight), nil)
            } catch {
                completionHandler(nil, nil, FileProviderErrors.map(error))
            }
        }
        return progress
    }

    /// Anything that would change something: refused, as nothing here can be.
    static var readOnly: Error { CocoaError(.fileWriteNoPermission) }
}

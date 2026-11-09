import ATDriveCore
import ATDriveMacSupport
import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

/// The File Provider extension: macOS runs it on demand to show the drive in Finder, download
/// files when they're opened, and upload changes made in Finder.
///
/// The system keeps the local copies; this class only moves data between them and the drive.
/// Every callback starts a task, does its work through `Drive`, and calls the completion handler.
@objc(ATDriveFileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let index = DriveIndex()
    private let logger = Logger(subsystem: Log.subsystem, category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("started for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        logger.info("invalidated")
    }

    // MARK: Reading

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            if identifier == .rootContainer { return completionHandler(Item.root, nil) }
            do {
                let tree = try await index.refresh().tree
                guard let node = tree.nodes[identifier.rawValue] else { throw NSFileProviderError(.noSuchItem) }
                completionHandler(Item(node, in: tree), nil)
            } catch {
                completionHandler(nil, fail("item", error))
            }
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws
        -> NSFileProviderEnumerator
    {
        switch containerItemIdentifier {
        case .workingSet: return Enumerator(scope: .workingSet, index: index)
        case .rootContainer: return Enumerator(scope: .container(nil), index: index)
        case .trashContainer: throw CocoaError(.featureUnsupported)
        default: return Enumerator(scope: .container(containerItemIdentifier.rawValue), index: index)
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let drive = try await index.drive()
                let tree = try await index.refresh().tree
                guard let node = tree.nodes[itemIdentifier.rawValue], !node.isFolder else {
                    throw NSFileProviderError(.noSuchItem)
                }
                progress.totalUnitCount = Int64(max(node.record.size ?? 0, 1))
                let destination = try temporaryFile()
                try await drive.download(node, to: destination) { done, _ in
                    progress.completedUnitCount = Int64(done)
                }
                completionHandler(destination, Item(node, in: tree), nil)
            } catch {
                completionHandler(nil, nil, fail("fetchContents", error))
            }
        }
        return progress
    }

    // MARK: Writing

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let drive = try await index.drive()
                let tree = try await index.refresh().tree
                let parent = try folderID(itemTemplate.parentItemIdentifier, in: tree)
                let name = itemTemplate.filename
                let type = (itemTemplate.contentType ?? nil) ?? .data
                if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
                    throw CocoaError(.featureUnsupported)  // not stored in the drive (yet)
                }
                let isFolder = type.conforms(to: .directory)

                if let existing = tree.child(named: name, in: parent) {
                    // When re-importing, the system may hand back things the drive already has.
                    let identical: Bool
                    if existing.isFolder != isFolder {
                        identical = false
                    } else if isFolder {
                        identical = true
                    } else if let url {
                        identical = try drive.isUnchanged(url, comparedTo: existing)
                    } else {
                        identical = existing.record.size == 0
                    }
                    if options.contains(.mayAlreadyExist), identical {
                        return completionHandler(Item(existing, in: tree), [], false, nil)
                    }
                    throw NSFileProviderError(.filenameCollision)
                }

                let node: Node
                if isFolder {
                    node = try await drive.createFolder(named: name, in: parent)
                } else {
                    let modified = (itemTemplate.contentModificationDate ?? nil)
                    node = try await drive.upload(
                        try url ?? emptyFile(), as: name, in: parent, modified: modified,
                        progress: Self.report(to: progress))
                }
                completionHandler(Item(node: node, parentID: parent), [], false, nil)
                signalChanges()
            } catch {
                completionHandler(nil, [], false, fail("createItem", error))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let drive = try await index.drive()
                let tree = try await index.refresh().tree
                guard let node = tree.nodes[item.itemIdentifier.rawValue] else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let currentParent = tree.parent(of: node.id)
                let parent =
                    try changedFields.contains(.parentItemIdentifier)
                    ? folderID(item.parentItemIdentifier, in: tree) : currentParent
                let name = changedFields.contains(.filename) ? item.filename : node.name
                let relocating = parent != currentParent || name != node.name
                if relocating {
                    if let clash = tree.child(named: name, in: parent), clash.id != node.id {
                        throw NSFileProviderError(.filenameCollision)
                    }
                    if node.isFolder, let parent, tree.isInside(parent, folder: node.id) {
                        throw CocoaError(.fileWriteNoPermission)  // a folder can't go inside itself
                    }
                }

                if changedFields.contains(.contents), let newContents, !node.isFolder {
                    let modified = (item.contentModificationDate ?? nil)
                    if version.contentVersion != Item.contentVersion(of: node) {
                        // The file changed on the drive since this edit was based on it. Keep both:
                        // the edit becomes a conflicted copy, and this item gets the drive's version.
                        let copy = Self.conflictName(for: name, in: parent, tree: tree)
                        _ = try await drive.upload(
                            newContents, as: copy, in: parent, modified: modified, progress: Self.report(to: progress))
                        let kept = try await relocating ? drive.move(node, to: parent, as: name) : node
                        logger.notice("conflict on \(node.id, privacy: .public): saved local edit as a copy")
                        completionHandler(Item(node: kept, parentID: parent), [], true, nil)
                    } else {
                        let updated = try await drive.upload(
                            newContents, as: name, in: parent, replacing: node, modified: modified,
                            progress: Self.report(to: progress))
                        completionHandler(Item(node: updated, parentID: parent), [], false, nil)
                    }
                } else if relocating {
                    let moved = try await drive.move(node, to: parent, as: name)
                    completionHandler(Item(node: moved, parentID: parent), [], false, nil)
                } else {
                    // Only metadata the drive doesn't store (tags, xattrs, dates): nothing to upload.
                    completionHandler(Item(node, in: tree), [], false, nil)
                }
                signalChanges()
            } catch {
                completionHandler(nil, [], false, fail("modifyItem", error))
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            do {
                let drive = try await index.drive()
                let tree = try await index.refresh().tree
                // Already gone is fine: the system just removes its local copy.
                guard let node = tree.nodes[identifier.rawValue] else { return completionHandler(nil) }
                var doomed = [node]
                if node.isFolder {
                    let inside = tree.descendants(of: node.id)
                    if !inside.isEmpty, !options.contains(.recursive) {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    doomed = inside + [node]
                }
                try await drive.delete(doomed)
                completionHandler(nil)
                signalChanges()
            } catch {
                completionHandler(fail("deleteItem", error))
            }
        }
        return progress
    }

    // MARK: Helpers

    /// The drive folder ID for a File Provider parent identifier (`nil` = top level).
    private func folderID(_ identifier: NSFileProviderItemIdentifier, in tree: DriveTree) throws -> String? {
        switch identifier {
        case .rootContainer: return nil
        case .trashContainer: throw CocoaError(.featureUnsupported)
        default:
            guard let folder = tree.nodes[identifier.rawValue], folder.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            return folder.id
        }
    }

    /// `report.pdf` → `report (conflicted copy 2026-11-09 1432).pdf`, unused in the folder.
    static func conflictName(for name: String, in parent: String?, tree: DriveTree) -> String {
        ConflictName.make(for: name) { tree.child(named: $0, in: parent) != nil }
    }

    private static func report(to progress: Progress) -> Drive.Progress {
        { done, total in
            progress.totalUnitCount = Int64(max(total, 1))
            progress.completedUnitCount = Int64(done)
        }
    }

    private func temporaryFile() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
        return try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
    }

    private func emptyFile() throws -> URL {
        let url = try temporaryFile()
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// Tells the system to ask for changes, so edits (and conflict copies) show up promptly.
    private func signalChanges() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    private func fail(_ operation: String, _ error: Error) -> Error {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return FileProviderErrors.map(error)
    }
}

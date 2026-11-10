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
    //
    // Changes from this Mac are settled against the drive with `ConflictRules`, the same rules
    // `atdrive sync` follows, using the version of each item that the system based its change on.

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
                let parent = try await folderID(itemTemplate.parentItemIdentifier, in: tree, drive: drive)
                var name = itemTemplate.filename
                let type = (itemTemplate.contentType ?? nil) ?? .data
                if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
                    throw CocoaError(.featureUnsupported)  // not stored in the drive (yet)
                }
                let isFolder = type.conforms(to: .directory)

                if let existing = tree.child(named: name, in: parent) {
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
                    // The same thing: pair them up, unless this Mac already has the drive's one
                    // under another name (e.g. renamed on the drive, not caught up yet).
                    let seenHere = await index.seenNode(existing.id) != nil
                    if identical, options.contains(.mayAlreadyExist) || !seenHere {
                        await index.noteSeen(existing, parent: parent)
                        return completionHandler(Item(existing, in: tree), [], false, nil)
                    }
                    // Different things with one name: the newcomer is renamed.
                    name = Self.conflictName(for: name, in: parent, tree: tree)
                    logger.notice("name clash in \(parent ?? "/", privacy: .public): new item renamed")
                }

                let node: Node
                if isFolder {
                    node = try await drive.createFolder(named: name, in: parent)
                } else {
                    let modified = (itemTemplate.contentModificationDate ?? nil)
                    node = try await drive.upload(
                        try url ?? emptyFile(), as: name, in: parent, modified: modified,
                        known: tree.chunkCIDs, progress: Self.report(to: progress))
                }
                await index.noteSeen(node, parent: parent)
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
                let modified = (item.contentModificationDate ?? nil)
                let edited = changedFields.contains(.contents) ? newContents : nil
                let editedSHA = try edited.map(Drive.sha256(of:))
                let baseSHA = Item.sha256(in: version)

                // On the drive, but this Mac can't read it now: never written over. The change
                // is tried again later, and settled once it can be read.
                if tree.unreadable[item.itemIdentifier.rawValue] != nil {
                    throw NSFileProviderError(.serverUnreachable)
                }
                guard let node = tree.nodes[item.itemIdentifier.rawValue] else {
                    // Deleted on the drive. Kept if it was edited here; otherwise the delete stands.
                    guard let edited, let editedSHA, !ConflictRules.deleteStands(base: baseSHA, other: editedSHA)
                    else { throw NSFileProviderError(.noSuchItem) }
                    let parent = (try? await folderID(item.parentItemIdentifier, in: tree, drive: drive)) ?? nil
                    var name = item.filename
                    if tree.child(named: name, in: parent) != nil {
                        name = Self.conflictName(for: name, in: parent, tree: tree)
                    }
                    // Back under its own ID, so this Mac's item and the drive's stay one thing. Its
                    // history goes on from the version this Mac last saw.
                    var record = NodeRecord(name: name, parent: parent, kind: .file)
                    record.version = await index.seenNode(item.itemIdentifier.rawValue)?.record.version
                    let gone = Node(id: item.itemIdentifier.rawValue, cid: "", record: record)
                    let restored = try await drive.upload(
                        edited, as: name, in: parent, replacing: gone, modified: modified,
                        known: tree.chunkCIDs, progress: Self.report(to: progress))
                    logger.notice("\(gone.id, privacy: .public) was deleted on the drive but edited here: kept")
                    await index.noteSeen(restored, parent: parent)
                    completionHandler(Item(node: restored, parentID: parent), [], false, nil)
                    signalChanges()
                    return
                }

                // Where it goes: a move on one side wins; moved on both sides, the drive's wins.
                let there = Item.Location(parent: tree.parent(of: node.id), name: node.name)
                let before = Item.location(in: version) ?? there  // versions from before it was recorded
                var here = before
                if changedFields.contains(.parentItemIdentifier) {
                    here.parent = try await folderID(item.parentItemIdentifier, in: tree, drive: drive)
                }
                if changedFields.contains(.filename) { here.name = item.filename }
                var target = ConflictRules.location(base: before, local: here, remote: there)
                if target != here {
                    logger.notice("\(node.id, privacy: .public) moved on both sides: kept the drive's move")
                }
                if node.isFolder, let parent = target.parent, tree.isInside(parent, folder: node.id) {
                    target = there  // a folder can't go inside itself: leave it where the drive has it
                }
                if target != there, let clash = tree.child(named: target.name, in: target.parent),
                    clash.id != node.id
                {
                    target.name = Self.conflictName(for: target.name, in: target.parent, tree: tree)
                }
                let relocating = target != there
                func placed() async throws -> Node {
                    guard relocating else { return node }
                    return try await drive.move(node, to: target.parent, as: target.name)
                }

                if let edited, let editedSHA, !node.isFolder {
                    switch ConflictRules.contents(base: baseSHA, local: editedSHA, remote: node.record.sha256) {
                    case .local:
                        let updated = try await drive.upload(
                            edited, as: target.name, in: target.parent, replacing: node, modified: modified,
                            known: tree.chunkCIDs, progress: Self.report(to: progress))
                        await index.noteSeen(updated, parent: target.parent)
                        completionHandler(Item(node: updated, parentID: target.parent), [], false, nil)
                    case .remote:
                        // Nothing new to upload: the drive has these contents, or this "edit"
                        // didn't change them. Fetch the drive's version if it differs.
                        let kept = try await placed()
                        await index.noteSeen(kept, parent: target.parent)
                        completionHandler(
                            Item(node: kept, parentID: target.parent), [], editedSHA != node.record.sha256, nil)
                    case .conflict:
                        // Edited on both sides: the drive's version keeps the name, and this
                        // edit is saved beside it as a conflicted copy.
                        let copy = Self.conflictName(for: target.name, in: target.parent, tree: tree)
                        _ = try await drive.upload(
                            edited, as: copy, in: target.parent, modified: modified,
                            known: tree.chunkCIDs, progress: Self.report(to: progress))
                        let kept = try await placed()
                        logger.notice("conflict on \(node.id, privacy: .public): saved local edit as a copy")
                        await index.noteSeen(kept, parent: target.parent)
                        completionHandler(Item(node: kept, parentID: target.parent), [], true, nil)
                    }
                } else if relocating {
                    let moved = try await placed()
                    await index.noteSeen(moved, parent: target.parent)
                    completionHandler(Item(node: moved, parentID: target.parent), [], false, nil)
                } else {
                    // Nothing the drive stores changed (tags, xattrs, dates), or the drive's move won.
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
                // Edited on the drive since this Mac saw it: the edit is kept, not deleted. A
                // folder keeps whatever in it changed on the drive since (and the rest goes).
                // What's kept is reported as changed, so the system puts it back here.
                let kept: Set<String>
                var doomed = [node]
                if node.isFolder {
                    let inside = tree.descendants(of: node.id)
                    if !inside.isEmpty, !options.contains(.recursive) {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    // Until the system has been given the whole drive, nothing inside counts as seen.
                    let seen = await index.seenTree() ?? DriveTree([])
                    kept = ConflictRules.keptWhenDeleting(folder: node.id, now: tree, seen: seen)
                    doomed = (inside + [node]).filter { !kept.contains($0.id) }
                } else if !ConflictRules.deleteStands(base: Item.sha256(in: version), other: node.record.sha256) {
                    kept = [node.id]
                    doomed = []
                } else {
                    kept = []
                }
                if !doomed.isEmpty { try await drive.delete(doomed) }
                if !kept.isEmpty {
                    logger.notice("delete of \(node.id, privacy: .public): kept \(kept.count) changed on the drive")
                    await index.resendNextTime(kept)
                }
                completionHandler(nil)
                signalChanges()
            } catch {
                completionHandler(fail("deleteItem", error))
            }
        }
        return progress
    }

    // MARK: Helpers

    /// The drive folder ID for a File Provider parent identifier (`nil` = top level). A folder
    /// deleted on the drive that something is going into here is put back, since a folder is
    /// kept if anything kept is inside it (`ConflictRules`).
    private func folderID(_ identifier: NSFileProviderItemIdentifier, in tree: DriveTree, drive: Drive)
        async throws -> String?
    {
        switch identifier {
        case .rootContainer: return nil
        case .trashContainer: throw CocoaError(.featureUnsupported)
        default:
            if let folder = tree.nodes[identifier.rawValue] {
                guard folder.isFolder else { throw NSFileProviderError(.noSuchItem) }
                return folder.id
            }
            // Still there, but unreadable here now: used as it is, never put back over.
            if tree.unreadable[identifier.rawValue] != nil { return identifier.rawValue }
            guard let gone = await index.seenNode(identifier.rawValue), gone.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            var record = gone.record
            let parent = gone.record.parent.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
            record.parent = (try? await folderID(parent, in: tree, drive: drive)) ?? nil
            try await drive.restore(Node(id: gone.id, cid: gone.cid, record: record))
            logger.notice("\(gone.id, privacy: .public) was deleted on the drive but used here: put back")
            return gone.id
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

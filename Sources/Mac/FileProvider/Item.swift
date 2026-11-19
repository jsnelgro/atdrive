import ATDriveCore
import ATDriveMacSupport
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// A drive node as the File Provider framework sees it.
final class Item: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    private let node: Node?
    private let parentID: String?
    let sharing: SharingRole

    /// The top of the drive.
    static let root = Item(node: nil, parentID: nil)

    /// The signed-in account, which tells its own shares from other people's (set by `DriveIndex`).
    static var account: String? {
        get { accountLock.withLock { storedAccount } }
        set { accountLock.withLock { storedAccount = newValue } }
    }
    private static let accountLock = NSLock()
    private nonisolated(unsafe) static var storedAccount: String?

    /// The Spaces folder as last read, and whether Spotlight may search it (set by `DriveIndex`):
    /// for badges and Spotlight's attribute.
    static var spaces: (folder: SpacesFolder?, spotlight: Bool) {
        get { accountLock.withLock { storedSpaces } }
        set { accountLock.withLock { storedSpaces = newValue } }
    }
    private nonisolated(unsafe) static var storedSpaces: (folder: SpacesFolder?, spotlight: Bool) = (nil, false)

    init(node: Node?, parentID: String?, tree: DriveTree? = nil) {
        self.node = node
        self.parentID = parentID
        sharing = node.map { SharingRole.of($0, in: tree, account: Self.account) } ?? .none
    }

    /// A node, placed in the folder the tree shows it in.
    convenience init(_ node: Node, in tree: DriveTree) {
        self.init(node: node, parentID: tree.parent(of: node.id), tree: tree)
    }

    /// For Finder's actions: which ones show (`NSExtensionFileProviderActions` in Info.plist).
    var userInfo: [AnyHashable: Any]? { ["sharing": sharing.rawValue] }

    /// The `Sharing` badges, and Spaces' "can't be read" (`NSFileProviderDecorations` in
    /// Info.plist). `atdrive spaces` says why a space can't be read.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        let bundle = Bundle.main.bundleIdentifier ?? "app.atdrive.fileprovider"
        switch sharing {
        case .own: return [NSFileProviderItemDecorationIdentifier("\(bundle).shared")]
        case .other: return [NSFileProviderItemDecorationIdentifier("\(bundle).sharedWithMe")]
        case .spaces:
            guard let node, Self.spaces.folder?.item(node.id)?.unreadable != nil else { return [] }
            return [NSFileProviderItemDecorationIdentifier("\(bundle).unreadable")]
        default: return []
        }
    }

    /// In Spaces, kept out of Spotlight's results unless `spaces.spotlight` is on: the
    /// deprecated, but still honoured, `kMDItemSupportFileType = MDSystemFile`, as system files
    /// have.
    var extendedAttributes: [String: Data] {
        guard sharing == .spaces, !Self.spaces.spotlight else { return [:] }
        return Self.hiddenFromSpotlight
    }

    static let hiddenFromSpotlight: [String: Data] = {
        guard
            let value = try? PropertyListSerialization.data(
                fromPropertyList: ["MDSystemFile"], format: .binary, options: 0)
        else { return [:] }
        return ["com.apple.metadata:kMDItemSupportFileType": value]
    }()

    var itemIdentifier: NSFileProviderItemIdentifier {
        node.map { NSFileProviderItemIdentifier($0.id) } ?? .rootContainer
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        parentID.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
    }

    var filename: String { node?.name ?? "ATDrive" }

    var contentType: UTType {
        guard let node, !node.isFolder else { return .folder }
        return UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? { node?.record.size.map { NSNumber(value: $0) } }
    var creationDate: Date? { node?.record.createdDate }
    var contentModificationDate: Date? { node?.record.modifiedDate ?? node?.record.createdDate }

    var capabilities: NSFileProviderItemCapabilities {
        guard let node else {
            return [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating]
        }
        switch sharing {
        case .insideOther, .spaces:
            // Shared with you, or another app's: only its owner changes it.
            return node.isFolder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        case .other:
            // The mount itself is yours, in your drive: it can be renamed, moved and removed.
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting,
            ]
            if node.isFolder { capabilities.insert(.allowsContentEnumerating) }
            return capabilities
        default:
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting,
            ]
            if node.isFolder {
                capabilities.formUnion([.allowsAddingSubItems, .allowsContentEnumerating])
            }
            return capabilities
        }
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Self.contentVersion(of: node), metadataVersion: metadataVersion)
    }

    /// Changes exactly when the file's bytes change (folders have no content): its SHA-256.
    static func contentVersion(of node: Node?) -> Data {
        Data((node?.record.sha256 ?? "folder").utf8)
    }

    /// The file's SHA-256 in a version the system hands back (what a change was based on).
    static func sha256(in version: NSFileProviderItemVersion) -> String {
        String(decoding: version.contentVersion, as: UTF8.self)
    }

    /// Where an item is: its folder (`nil` = top level) and name.
    struct Location: Codable, Equatable {
        var parent: String?
        var name: String
    }

    /// Changes when anything about the record changes, or it's shown in a different folder. It
    /// also records the folder and name, so a change can be compared with where the item was
    /// when the change was made (`ConflictRules.location`).
    private var metadataVersion: Data {
        struct Metadata: Encodable {
            var cid: String
            var parent: String?
            var name: String
            /// In Spaces: whether Spotlight may search it (it changes the item's attributes).
            var indexed: Bool?
        }
        let indexed = sharing == .spaces ? Self.spaces.spotlight : nil
        let metadata = Metadata(cid: node?.cid ?? "root", parent: parentID, name: filename, indexed: indexed)
        return (try? Self.encoder.encode(metadata)) ?? Data()
    }

    /// The folder and name in a version the system hands back. `nil` for versions made before
    /// they were recorded.
    static func location(in version: NSFileProviderItemVersion) -> Location? {
        try? JSONDecoder().decode(Location.self, from: version.metadataVersion)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

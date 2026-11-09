import ATDriveCore
import FileProvider
import UniformTypeIdentifiers

/// A drive node as the File Provider framework sees it.
final class Item: NSObject, NSFileProviderItem {
    private let node: Node?
    private let parentID: String?

    /// The top of the drive.
    static let root = Item(node: nil, parentID: nil)

    init(node: Node?, parentID: String?) {
        self.node = node
        self.parentID = parentID
    }

    /// A node, placed in the folder the tree shows it in.
    convenience init(_ node: Node, in tree: DriveTree) {
        self.init(node: node, parentID: tree.parent(of: node.id))
    }

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
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting,
        ]
        if node.isFolder {
            capabilities.formUnion([.allowsAddingSubItems, .allowsContentEnumerating])
        }
        return capabilities
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
        }
        let metadata = Metadata(cid: node?.cid ?? "root", parent: parentID, name: filename)
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

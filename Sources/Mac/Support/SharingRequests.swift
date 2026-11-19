import ATDriveCore
import Foundation

/// How Finder's sharing actions reach the menu-bar app. The File Provider extension can't show
/// windows, so a custom action (Share…, Copy Link, Stop Sharing) writes a request into the App
/// Group container and posts a Darwin notification; the app, which listens for it, reads the
/// request and does the rest (a window, the pasteboard, a confirmation).
public struct SharingRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case share, copyLink, stopSharing
    }

    public var action: Action
    /// The item's identifier (a node ID: `NodeID`).
    public var item: String
    public var requestedAt: Date

    public init(action: Action, item: String, requestedAt: Date = Date()) {
        self.action = action
        self.item = item
        self.requestedAt = requestedAt
    }

    /// The Darwin notification the app listens for.
    public static let notification = "me.jsnelgro.atdrive.sharing-request"

    static var file: URL? { AppGroup.containerURL?.appendingPathComponent("Library/Caches/sharing-request.json") }

    /// Hands the request to the app (from the extension).
    public func post() throws {
        guard let file = Self.file else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(Self.notification as CFString), nil, nil,
            true)
    }

    /// The request waiting, if any, taken so it's handled once (in the app). One older than a
    /// minute is dropped: it's from before the app was running.
    public static func take() -> SharingRequest? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard let request = try? JSONDecoder().decode(SharingRequest.self, from: data),
            request.requestedAt.timeIntervalSinceNow > -60
        else { return nil }
        return request
    }
}

/// What an item is to sharing, as Finder's actions and badges see it (`Item.userInfo["sharing"]`).
public enum SharingRole: String, Sendable {
    /// Not shared, and not in anything shared.
    case none
    /// A share of yours (its mount).
    case own
    /// Something shared with you (its mount): read-only inside.
    case other
    /// Inside a share of yours.
    case insideOwn
    /// Inside something shared with you: read-only.
    case insideOther
    /// The Spaces folder, or in it (#28): other apps' data, read-only, and never shared.
    case spaces

    /// An item's role, from its node, the tree it's in, and the signed-in account.
    public static func of(_ node: Node, in tree: DriveTree?, account: String?) -> SharingRole {
        if SpacesFolder.contains(node.id) { return .spaces }
        if node.isMount { return node.record.mount?.owner == account ? .own : .other }
        guard let mount = NodeID.split(node.id).mount else { return .none }
        guard let owner = tree?.nodes[mount]?.record.mount?.owner ?? tree?.unreadable[mount].map({ _ in "" }) else {
            // Written just now: only into a space of yours.
            return .insideOwn
        }
        return owner == account ? .insideOwn : .insideOther
    }
}

import Foundation

public enum SyncError: Error, CustomStringConvertible, Equatable {
    case folderMissing(String)
    case stateMissing(String)
    case otherAccount(folder: String, owner: String)
    case alreadyRunning(String)
    case notAFolder(String)

    public var description: String {
        switch self {
        case .folderMissing(let folder):
            "\(folder) is gone, so syncing stopped (nothing was deleted from the drive)"
        case .stateMissing(let folder):
            "\(folder)/\(SyncIgnore.stateFolder) was removed, so syncing stopped. Run `atdrive sync` again "
                + "to start over: the folder and the drive are merged, and nothing is deleted"
        case .otherAccount(let folder, let owner):
            "\(folder) is synced with another account's drive (\(owner))"
        case .alreadyRunning(let folder):
            "\(folder) is already being synced by another `atdrive sync`"
        case .notAFolder(let path):
            "\(path) is not a folder"
        }
    }
}

/// Something the sync did, for the log.
public struct SyncEvent: Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// From the folder to the drive.
        case uploaded, createdFolderOnDrive, movedOnDrive, deletedFromDrive
        /// From the drive to the folder.
        case downloaded, createdFolderHere, movedHere, deletedHere
        /// Edited in both places: both versions kept (`detail` is the copy).
        case conflict
        /// Two different things with one name: one renamed (`detail` is its new path).
        case renamed
        /// Left alone for now (`detail` says why); tried again next time.
        case skipped
    }

    public var kind: Kind
    /// Where it is in the drive (and folder): `/docs/a.txt`.
    public var path: String
    /// The destination of a move, the name of a copy, or why something was skipped.
    public var detail: String?

    public init(_ kind: Kind, _ path: String, _ detail: String? = nil) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }

    public var description: String {
        switch kind {
        case .uploaded: "↑ \(path)"
        case .createdFolderOnDrive: "↑ \(path)/"
        case .movedOnDrive: "↑ moved \(path) → \(detail ?? "")"
        case .deletedFromDrive: "↑ deleted \(path)"
        case .downloaded: "↓ \(path)"
        case .createdFolderHere: "↓ \(path)/"
        case .movedHere: "↓ moved \(path) → \(detail ?? "")"
        case .deletedHere: "↓ deleted \(path)"
        case .conflict: "! \(path) changed in both places. Kept both: your version is \(detail ?? "")"
        case .renamed: "! two different items were named \(path); one is now \(detail ?? "")"
        case .skipped: "? skipped \(path): \(detail ?? "")"
        }
    }
}

/// What the last sync left in agreement between the folder and the drive: one entry per node,
/// with the local file's `lstat` at the time. Changes on each side are found by comparing it
/// with that side now.
struct SyncState: Codable {
    struct Item: Codable, Equatable {
        var parent: String?
        var name: String
        var folder: Bool
        var sha256: String?
        var stat: FileStat
    }

    static let currentVersion = 1

    var version = currentVersion
    /// The drive's owner (DID) and space: a folder is only ever synced with one drive.
    var owner: String
    var space: String
    /// By node ID.
    var items: [String: Item] = [:]
}

/// The `.atdrive` folder inside a synced folder: the state file, a lock so only one sync runs,
/// and scratch space for downloads and moves (on the same disk, so renames are atomic).
struct StateFolder {
    let root: String
    var path: String { "\(root)/\(SyncIgnore.stateFolder)" }
    var stateFile: String { "\(path)/state.json" }
    var lockFile: String { "\(path)/lock" }
    var staging: String { "\(path)/staging" }
    var journal: String { "\(path)/staging.json" }
    var downloads: String { "\(path)/downloads" }

    func load() throws -> SyncState? {
        guard let data = FileManager.default.contents(atPath: stateFile) else { return nil }
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    func save(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let temporary = "\(path)/.state.json.tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: try encoder.encode(state)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        try replace(URL(fileURLWithPath: stateFile), with: URL(fileURLWithPath: temporary))
    }

    /// Takes the lock for as long as the returned descriptor stays open.
    func lock() throws -> Int32 {
        let descriptor = open(lockFile, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile])
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SyncError.alreadyRunning(root)
        }
        return descriptor
    }
}

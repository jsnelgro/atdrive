import Foundation

/// What `lstat` says about a file: enough to tell, without reading it, whether it may have
/// changed since last time, and (by device and inode) where it went if it was renamed.
public struct FileStat: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    /// Last content change and last status change (content, permissions, rename), in
    /// nanoseconds since 1970.
    public var modified: Int64
    public var changed: Int64
}

/// What ATDrive uses itself, so never syncs or uploads, whatever the ignore settings: the sync's
/// state folder at the top of a synced folder (`StateFolder`), and half-finished downloads.
/// Everything else that's left out is up to the ignore rules (`IgnoreRules`); the clutter file
/// browsers and editors leave around is in their defaults (`IgnoreSettings.defaultPatterns`).
public enum SyncIgnore {
    /// The folder at the top of a synced folder that holds the sync's own state.
    public static let stateFolder = ".atdrive"
    /// A download in progress (`.<name>.atdrive-partial`), renamed into place when it's done.
    public static let partialSuffix = ".atdrive-partial"

    public static func isIgnored(_ name: String, atTop: Bool) -> Bool {
        (atTop && name == stateFolder) || name.hasSuffix(partialSuffix)
    }

    /// Whether anything along a relative path (`a/b/c`) is ignored.
    static func isIgnored(path components: some Collection<String>) -> Bool {
        components.enumerated().contains { isIgnored($0.element, atTop: $0.offset == 0) }
    }
}

/// The few POSIX file operations the sync needs, on plain paths. Unlike most of Foundation's,
/// they never follow symlinks and never replace something that's already there.
enum LocalFS {
    enum Kind { case file, folder, other }

    static func status(_ path: String) -> (kind: Kind, stat: FileStat)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
            let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            let changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
            let device = UInt64(UInt32(bitPattern: info.st_dev))
        #else
            let modified = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
            let changed = Int64(info.st_ctim.tv_sec) * 1_000_000_000 + Int64(info.st_ctim.tv_nsec)
            let device = UInt64(info.st_dev)
        #endif
        let kind: Kind =
            switch info.st_mode & S_IFMT {
            case S_IFREG: .file
            case S_IFDIR: .folder
            default: .other
            }
        return (
            kind,
            FileStat(
                device: device, inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: modified,
                changed: changed)
        )
    }

    static func exists(_ path: String) -> Bool { status(path) != nil }

    static func isFolder(_ path: String) -> Bool { status(path)?.kind == .folder }

    /// Renames `from` to `to`, unless something is already at `to`.
    @discardableResult
    static func move(_ from: String, to: String) -> Bool {
        guard !exists(to) else { return false }
        return rename(from, to) == 0
    }

    @discardableResult
    static func makeFolder(_ path: String) -> Bool {
        mkdir(path, 0o777) == 0 || isFolder(path)
    }

    @discardableResult
    static func removeFile(_ path: String) -> Bool { unlink(path) == 0 }

    /// Removes an empty folder. Ignored clutter (`.DS_Store`, swap files…) doesn't count as
    /// content: it's removed first.
    @discardableResult
    static func removeFolder(_ path: String) -> Bool {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        where disposable.contains(name) && status("\(path)/\(name)")?.kind == .file {
            unlink("\(path)/\(name)")
        }
        return rmdir(path) == 0
    }

    /// Files a file browser makes in any folder it shows, which go when the folder does (when it's
    /// deleted on the drive). Anything else ignored keeps the folder here, editors' swap files
    /// included: they may hold unsaved work.
    static let disposable: Set<String> = [".DS_Store", "Thumbs.db"]

    /// Copies permission bits from one file to another.
    static func copyPermissions(from source: String, to destination: String) {
        var info = stat()
        guard lstat(source, &info) == 0 else { return }
        chmod(destination, info.st_mode & 0o7777)
    }

    static func sha256(_ path: String) throws -> String { try Drive.sha256(of: URL(fileURLWithPath: path)) }

    static func errorDescription(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }
}

/// One look at everything in a synced folder (without reading any file).
struct FolderScan {
    struct Item {
        var isFolder: Bool
        var stat: FileStat
    }

    /// By path relative to the folder, `a/b/c.txt`.
    var items: [String: Item] = [:]
    /// Folders whose contents couldn't be listed (relative paths).
    var unreadable: Set<String> = []
    /// Symlinks, sockets and the like, which aren't synced (relative paths).
    var skipped: [String] = []
    /// The ignore rules, with every ignore file in the folder read. What they ignore isn't
    /// listed, or looked inside.
    var ignore: IgnoreRules
    /// What they ignore: the outermost things only (an ignored folder, not what's in it).
    var ignored: [(path: String, isFolder: Bool)] = []

    init(root: String, ignore settings: IgnoreSettings = IgnoreSettings()) throws {
        guard LocalFS.isFolder(root) else { throw SyncError.folderMissing(root) }
        ignore = IgnoreRules(settings)
        var stack = [""]
        while let folder = stack.popLast() {
            let absolute = folder.isEmpty ? root : "\(root)/\(folder)"
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: absolute)
            } catch {
                if folder.isEmpty { throw SyncError.folderMissing(root) }
                unreadable.insert(folder)
                continue
            }
            // Before anything in the folder is looked at: its own ignore files apply to it.
            ignore.read(folder: folder, in: root, names: Set(names))
            for name in names where !SyncIgnore.isIgnored(name, atTop: folder.isEmpty) {
                let path = folder.isEmpty ? name : "\(folder)/\(name)"
                guard (try? DrivePath.validate(name: name)) != nil, let (kind, stat) = LocalFS.status("\(root)/\(path)")
                else { continue }
                if kind != .other, ignore.matches(path, isFolder: kind == .folder) {
                    ignored.append((path, kind == .folder))
                    continue
                }
                switch kind {
                case .folder:
                    items[path] = Item(isFolder: true, stat: stat)
                    stack.append(path)
                case .file:
                    items[path] = Item(isFolder: false, stat: stat)
                case .other:
                    skipped.append(path)
                }
            }
        }
    }
}

extension String {
    /// `a/b/c` → `a/b`; `a` → ``.
    var parentPath: String {
        guard let slash = lastIndex(of: "/") else { return "" }
        return String(self[..<slash])
    }

    var depth: Int { split(separator: "/").count }

    /// Whether this relative path is `folder` or inside it.
    func isWithin(_ folder: String) -> Bool { self == folder || hasPrefix(folder + "/") }
}

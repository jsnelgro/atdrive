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

/// Names the sync never copies in either direction: its own state folder, half-finished
/// downloads, and lock, swap and metadata files that editors and file browsers leave around.
public enum SyncIgnore {
    /// The folder at the top of a synced folder that holds the sync's own state.
    public static let stateFolder = ".atdrive"

    public static func isIgnored(_ name: String, atTop: Bool) -> Bool {
        if atTop, name == stateFolder { return true }
        if name == ".DS_Store" || name == "Thumbs.db" || name.hasSuffix(".atdrive-partial") { return true }
        // Vim swap files: .name.swp, .swo, ….
        if name.hasPrefix("."), name.count > 4 {
            let tail = name.suffix(4)
            if tail.hasPrefix(".sw"), tail.last!.isLetter { return true }
        }
        // LibreOffice and Microsoft Office lock files; Emacs autosave and lock files.
        if name.hasPrefix(".~lock.") || name.hasPrefix("~$") || name.hasPrefix(".#") { return true }
        if name.count > 1, name.hasPrefix("#"), name.hasSuffix("#") { return true }
        return false
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
        where SyncIgnore.isIgnored(name, atTop: false) && status("\(path)/\(name)")?.kind == .file {
            unlink("\(path)/\(name)")
        }
        return rmdir(path) == 0
    }

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

    init(root: String) throws {
        guard LocalFS.isFolder(root) else { throw SyncError.folderMissing(root) }
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
            for name in names where !SyncIgnore.isIgnored(name, atTop: folder.isEmpty) {
                let path = folder.isEmpty ? name : "\(folder)/\(name)"
                guard (try? DrivePath.validate(name: name)) != nil, let (kind, stat) = LocalFS.status("\(root)/\(path)")
                else { continue }
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

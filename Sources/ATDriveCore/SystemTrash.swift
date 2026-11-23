import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// This computer's own trash (not the drive's): where files that were never in the drive go when
/// ATDrive deletes them (`atdrive dev delete-ignored`), so they can be put back. The Trash on a
/// Mac; on Linux, the freedesktop.org trash that GNOME, KDE and the like show (and `gio trash`
/// works with), in `~/.local/share/Trash` or, for another disk, a `.Trash-<uid>` folder at its top.
public enum SystemTrash {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Moves a file or folder to the trash. `homeTrash`: the trash folder to use instead of the
    /// standard one (for tests).
    public static func move(_ path: String, homeTrash: String? = nil) throws {
        #if os(Linux)
            try freedesktop(path, homeTrash: homeTrash ?? standardHomeTrash)
        #else
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        #endif
    }

    #if os(Linux)
        /// `$XDG_DATA_HOME/Trash`, or `~/.local/share/Trash`.
        static var standardHomeTrash: String {
            let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            return "\(data ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share")/Trash"
        }

        /// The freedesktop.org Trash specification (1.0): reserve a name with its `.trashinfo`
        /// file, then rename the thing into `files/`. A rename can't cross disks, so something on
        /// another disk goes to `<its disk's top>/.Trash-<uid>` instead.
        static func freedesktop(_ path: String, homeTrash: String) throws {
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let device = self.device(absolute) else { throw Failure(description: "\(path) isn't there") }
            try makeFolder(homeTrash)
            var trash = homeTrash
            var recordedPath = absolute
            if self.device(homeTrash) != device {
                let top = topOfDisk(absolute, device: device)
                trash = "\(top == "/" ? "" : top)/.Trash-\(getuid())"
                try makeFolder(trash)
                recordedPath = String(absolute.dropFirst(top == "/" ? 1 : top.count + 1))
            }
            try makeFolder("\(trash)/files")
            try makeFolder("\(trash)/info")

            let name = URL(fileURLWithPath: absolute).lastPathComponent
            let info = """
                [Trash Info]
                Path=\(escape(recordedPath))
                DeletionDate=\(deletionDate())

                """
            for attempt in 1...10_000 {
                let candidate = attempt == 1 ? name : "\(name).\(attempt)"
                let infoFile = "\(trash)/info/\(candidate).trashinfo"
                // O_EXCL: the name is ours once this file exists.
                let descriptor = open(infoFile, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                if descriptor < 0 {
                    if errno == EEXIST { continue }
                    throw Failure(description: "couldn't write \(infoFile): \(String(cString: strerror(errno)))")
                }
                let written = Array(info.utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                close(descriptor)
                guard written == info.utf8.count, rename(absolute, "\(trash)/files/\(candidate)") == 0 else {
                    let why = String(cString: strerror(errno))
                    unlink(infoFile)
                    throw Failure(description: "couldn't move \(path) to the trash: \(why)")
                }
                return
            }
            throw Failure(description: "couldn't find a free name for \(name) in \(trash)")
        }

        static func device(_ path: String) -> UInt64? {
            var info = stat()
            return lstat(path, &info) == 0 ? UInt64(info.st_dev) : nil
        }

        /// The highest folder above `path` on the same disk (its mount point).
        static func topOfDisk(_ path: String, device: UInt64) -> String {
            var top = path
            while top != "/" {
                let parent = URL(fileURLWithPath: top).deletingLastPathComponent().standardizedFileURL.path
                guard self.device(parent) == device else { break }
                top = parent
            }
            return top
        }

        static func makeFolder(_ path: String) throws {
            if mkdir(path, 0o700) != 0, errno != EEXIST {
                throw Failure(description: "couldn't make \(path): \(String(cString: strerror(errno)))")
            }
        }

        /// The spec's URL escaping: everything but unreserved characters and `/`.
        static func escape(_ path: String) -> String {
            var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            allowed.insert(charactersIn: "-._~/")
            return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        }

        /// Local time, `YYYY-MM-DDThh:mm:ss`.
        static func deletionDate(_ date: Date = Date()) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return formatter.string(from: date)
        }
    #endif
}

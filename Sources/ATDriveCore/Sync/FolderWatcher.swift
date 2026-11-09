import Foundation

/// Wakes a sync loop soon after something in the folder changes, so edits go up in about a
/// second instead of at the next poll.
///
/// On Linux it uses inotify, one watch per folder (`watch(_:)` keeps the set current). It only
/// says *that* something changed: the sync's own scan works out what. Elsewhere, or past the
/// system's watch limit (`fs.inotify.max_user_watches`), `isWatching` is false and the caller
/// should poll.
public final class FolderWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var lastEvent = ContinuousClock.now
    private var watches: [String: Int32] = [:]
    private var paths: [Int32: String] = [:]
    private var limitReached = false
    #if os(Linux)
        private let descriptor: Int32
        private var stopped = false
    #endif

    public init() {
        #if os(Linux)
            descriptor = inotify_init1(Int32(IN_CLOEXEC))
            guard descriptor >= 0 else { return }
            let thread = Thread { [weak self] in
                guard let descriptor = self?.descriptor else { return }
                FolderWatcher.readEvents(descriptor) { self }
            }
            thread.name = "atdrive-watcher"
            thread.start()
        #endif
    }

    deinit {
        #if os(Linux)
            lock.withLock { stopped = true }
        #endif
    }

    /// Whether changes are noticed as they happen (otherwise, poll).
    public var isWatching: Bool {
        #if os(Linux)
            descriptor >= 0 && !lock.withLock { limitReached }
        #else
            false
        #endif
    }

    /// Watches exactly these folders (absolute paths), adding and removing watches as needed.
    public func watch(_ folders: [String]) {
        #if os(Linux)
            guard descriptor >= 0 else { return }
            let wanted = Set(folders)
            lock.withLock {
                // Removals first: a folder that moved keeps its watch, and re-adding it by its
                // new path would otherwise return the watch that's about to be removed.
                for (path, watch) in watches where !wanted.contains(path) {
                    inotify_rm_watch(descriptor, watch)
                    watches[path] = nil
                    paths[watch] = nil
                }
                let mask = UInt32(
                    IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF
                        | IN_MOVE_SELF | IN_ONLYDIR | IN_DONT_FOLLOW | IN_EXCL_UNLINK)
                for path in wanted.sorted() where watches[path] == nil {
                    let watch = inotify_add_watch(descriptor, path, mask)
                    if watch >= 0 {
                        watches[path] = watch
                        paths[watch] = path
                    } else if errno == ENOSPC {
                        limitReached = true
                        break
                    }
                }
            }
        #endif
    }

    /// A marker to pass to `wait(since:timeout:)`: take it before syncing, so changes made
    /// during the sync wake the next wait right away.
    public func mark() -> Int { lock.withLock { events } }

    /// Returns `true` once something changed since `mark` and then nothing more for `quiet`
    /// (so a burst of writes, like an editor saving, is one wake-up), or `false` after
    /// `timeout`. Without watching, just waits out `timeout`.
    @discardableResult
    public func wait(since mark: Int, timeout: Duration, quiet: Duration = .milliseconds(700)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if isWatching, lock.withLock({ events }) != mark {
                let start = clock.now
                while clock.now - lock.withLock({ lastEvent }) < quiet, clock.now - start < .seconds(5) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return true
            }
            try? await Task.sleep(for: min(.milliseconds(200), deadline - clock.now))
        }
        return false
    }

    #if os(Linux)
        private func noticed(_ buffer: UnsafeRawBufferPointer) {
            lock.withLock {
                var offset = 0
                while offset + MemoryLayout<inotify_event>.size <= buffer.count {
                    let event = buffer.loadUnaligned(fromByteOffset: offset, as: inotify_event.self)
                    if event.mask & UInt32(IN_IGNORED) != 0, let path = paths.removeValue(forKey: event.wd) {
                        watches[path] = nil
                    }
                    offset += MemoryLayout<inotify_event>.size + Int(event.len)
                }
                events += 1
                lastEvent = .now
            }
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        /// Reads events until the watcher goes away, then closes the descriptor.
        private static func readEvents(_ descriptor: Int32, watcher: () -> FolderWatcher?) {
            defer { close(descriptor) }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while let current = watcher(), !current.isStopped {
                guard poll(&poller, 1, 500) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { return }
                buffer.withUnsafeBytes { current.noticed(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
        }
    #endif
}

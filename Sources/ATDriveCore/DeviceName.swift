import Foundation

/// A name for this device, recorded on every change it makes (`VersionRecord.device`), so
/// history can say where a change came from. It's the `ATDRIVE_DEVICE` environment variable if
/// that's set, else the host name; either way it stays the same from one run to the next.
public enum DeviceName {
    public static let current: String = {
        if let configured = ProcessInfo.processInfo.environment["ATDRIVE_DEVICE"], !configured.isEmpty {
            return configured
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown" }
        var name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name.isEmpty ? "unknown" : name
    }()
}

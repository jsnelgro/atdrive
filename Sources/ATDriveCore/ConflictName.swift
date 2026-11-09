import Foundation

/// Names for the second copy when two versions of a file can't share one name: edited in two
/// places at once, or two different files given the same name.
public enum ConflictName {
    /// `report.pdf` → `report (conflicted copy 2026-11-09 1432).pdf`, or `… 1432 2).pdf` and so on
    /// if that's taken. Never longer than a name can be (255 bytes).
    public static func make(for name: String, at date: Date = Date(), isTaken: (String) -> Bool) -> String {
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let suffix = " (conflicted copy \(formatter.string(from: date))"
        func candidate(_ counter: Int) -> String {
            let base = stem + suffix + (counter > 1 ? " \(counter))" : ")")
            return ext.isEmpty ? base : "\(base).\(ext)"
        }
        var counter = 1
        while true {
            var name = candidate(counter)
            while name.utf8.count > 255, !stem.isEmpty {
                stem.removeLast()
                name = candidate(counter)
            }
            if !isTaken(name) { return name }
            counter += 1
        }
    }
}

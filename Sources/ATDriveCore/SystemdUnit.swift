import Foundation

/// Writing and reading the command line in the systemd unit `atdrive sync --install` writes.
public enum SystemdUnit {
    /// `%` starts a specifier anywhere in a unit file.
    public static func escape(_ text: String) -> String { text.replacingOccurrences(of: "%", with: "%%") }

    /// Quotes a word for a unit file; in commands, `$` also expands variables.
    public static func quote(_ word: String, forCommand: Bool) -> String {
        var escaped = escape(
            word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))
        if forCommand { escaped = escaped.replacingOccurrences(of: "$", with: "$$") }
        return "\"\(escaped)\""
    }

    /// The words of a unit's `ExecStart=` line, as `quote` wrote them; `nil` if there's none.
    public static func command(in unit: String) -> [String]? {
        guard let line = unit.split(separator: "\n").first(where: { $0.hasPrefix("ExecStart=") }) else { return nil }
        let characters = Array(line.dropFirst("ExecStart=".count))
        var words: [String] = []
        var word: String?
        var index = 0
        while index < characters.count {
            let c = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard word != nil else {
                if c == "\"" { word = "" }
                index += 1
                continue
            }
            if c == "\\", let next {
                word!.append(next)
                index += 2
            } else if c == "%" || c == "$", next == c {
                word!.append(c)
                index += 2
            } else if c == "\"" {
                words.append(word!)
                word = nil
                index += 1
            } else {
                word!.append(c)
                index += 1
            }
        }
        return words
    }
}

import Foundation

/// What decides which files ATDrive leaves alone, besides the built-in ones (`SyncIgnore`):
/// `.atdriveignore` files (always), `.gitignore` files (unless `gitignore` is off), and
/// `patterns`, from config.toml (`ignore.*`).
public struct IgnoreSettings: Sendable, Equatable, Codable {
    /// Whether `.gitignore` files count too.
    public var gitignore = true
    /// Lines of a `.atdriveignore` at the top of everything this computer syncs or uploads, below
    /// every ignore file in precedence (like git's `core.excludesFile`).
    public var patterns: [String] = []

    public init(gitignore: Bool = true, patterns: [String] = []) {
        self.gitignore = gitignore
        self.patterns = patterns
    }

    /// Nothing ignored but the built-in names: what `--no-ignore` asks for.
    public static let none = IgnoreSettings(gitignore: false, patterns: [])
}

/// Ignore rules for one folder tree (a synced folder, or a folder being uploaded), with
/// `.gitignore`'s meaning exactly (see `IgnorePattern`), combined as git combines them:
///
/// - The last matching line wins; a deeper folder's file beats a shallower one's.
/// - In one folder, `.atdriveignore` beats `.gitignore` (so it can bring back what git ignores).
/// - `IgnoreSettings.patterns` come last, relative to the top.
/// - Nothing in an ignored folder can be brought back: callers don't look inside one (a walk
///   doesn't descend; `Lookup` checks the folders on the way).
///
/// Ignore files are added folder by folder (`read(folder:in:)` from disk, or `add`), before
/// anything in that folder is asked about.
public struct IgnoreRules: Sendable {
    public static let fileName = ".atdriveignore"
    public static let gitFileName = ".gitignore"
    /// Bigger ignore files are skipped (nobody writes one; something else is going on).
    public static let maximumFileSize = 1 << 20

    public let settings: IgnoreSettings
    private let global: [IgnorePattern]
    /// Each folder's patterns (relative path, `""` for the top): `.gitignore`'s, then
    /// `.atdriveignore`'s, so the later ones win.
    private var folders: [String: [IgnorePattern]] = [:]

    public init(_ settings: IgnoreSettings) {
        self.settings = settings
        global = settings.patterns.compactMap(IgnorePattern.init)
    }

    /// Whether nothing at all can be ignored (no patterns anywhere yet).
    public var isEmpty: Bool { global.isEmpty && folders.isEmpty }

    /// Adds a folder's ignore files, given their text. `gitignore` is skipped if the settings
    /// say so.
    public mutating func add(folder: String, atdriveignore: String?, gitignore: String?) {
        var patterns: [IgnorePattern] = []
        if settings.gitignore, let gitignore { patterns += IgnorePattern.parse(gitignore) }
        if let atdriveignore { patterns += IgnorePattern.parse(atdriveignore) }
        if patterns.isEmpty { folders[folder] = nil } else { folders[folder] = patterns }
    }

    /// Reads a folder's ignore files from disk: `folder` relative to `root`. `names`: what's in
    /// the folder, if already listed (saves looking for files that aren't there).
    public mutating func read(folder: String, in root: String, names: Set<String>? = nil) {
        let absolute = folder.isEmpty ? root : "\(root)/\(folder)"
        func text(_ name: String) -> String? {
            if let names, !names.contains(name) { return nil }
            let path = "\(absolute)/\(name)"
            // Regular files only, like git (which doesn't follow a symlinked .gitignore).
            guard let (kind, stat) = LocalFS.status(path), kind == .file, stat.size <= Self.maximumFileSize,
                let data = FileManager.default.contents(atPath: path)
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        add(
            folder: folder, atdriveignore: text(Self.fileName),
            gitignore: settings.gitignore ? text(Self.gitFileName) : nil)
    }

    /// Whether something is ignored by its own path, its folders taken as not ignored: what a
    /// walk that doesn't descend into ignored folders asks. `path` is relative (`a/b/c.txt`).
    public func matches(_ path: String, isFolder: Bool) -> Bool {
        matches(path.split(separator: "/").map(String.init), isFolder: isFolder)
    }

    public func matches(_ components: [String], isFolder: Bool) -> Bool {
        guard !isEmpty, !components.isEmpty else { return false }
        // The folder the thing is in first, then each one above it, then the global patterns.
        for depth in stride(from: components.count - 1, through: 0, by: -1) {
            let folder = components[..<depth].joined(separator: "/")
            guard let patterns = folders[folder] else { continue }
            let relative = components[depth...]
            if let decided = Self.decide(patterns, relative, isFolder: isFolder) { return decided }
        }
        return Self.decide(global, components[...], isFolder: isFolder) ?? false
    }

    /// The last pattern that matches decides: ignored, or (`!`) not.
    private static func decide(_ patterns: [IgnorePattern], _ relative: ArraySlice<String>, isFolder: Bool) -> Bool? {
        guard !patterns.isEmpty else { return nil }
        let path = relative.joined(separator: "/")
        let name = relative.last!
        for pattern in patterns.reversed() where pattern.matches(path: path, name: name, isFolder: isFolder) {
            return !pattern.negated
        }
        return nil
    }

    /// The ignore files kept in a drive that apply to what's in `folder` (a node ID, `nil` for
    /// the top), top down: each folder's path (`""` for the top) and its ignore files, for `add`.
    /// For something that reads the rules from the drive rather than a local folder (the Mac
    /// app). `.gitignore` files only if the settings count them.
    public static func files(for folder: String?, in tree: DriveTree, settings: IgnoreSettings) -> [(
        folder: String, atdriveignore: Node?, gitignore: Node?
    )] {
        var chain: [String?] = [nil]
        var current = folder
        while let id = current, tree.nodes[id] != nil, chain.count < 4096, !chain.contains(id) {
            chain.insert(id, at: 1)
            current = tree.parent(of: id)
        }
        return chain.map { id in
            let path = id.flatMap { tree.nodes[$0] }.map { tree.path(of: $0).components.joined(separator: "/") } ?? ""
            func file(_ name: String) -> Node? {
                tree.child(named: name, in: id).flatMap { $0.isFolder ? nil : $0 }
            }
            return (path, file(fileName), settings.gitignore ? file(gitFileName) : nil)
        }
    }

    /// Answers for any path, its folders included (something in an ignored folder is ignored),
    /// remembering folders already decided. For things listed in no particular order, like the
    /// drive's nodes.
    public struct Lookup {
        public let rules: IgnoreRules
        private var decided: [String: Bool] = [:]

        public init(_ rules: IgnoreRules) { self.rules = rules }

        public mutating func isIgnored(_ components: [String], isFolder: Bool) -> Bool {
            guard !rules.isEmpty, !components.isEmpty else { return false }
            if components.count > 1, folderIsIgnored(Array(components.dropLast())) { return true }
            return rules.matches(components, isFolder: isFolder)
        }

        private mutating func folderIsIgnored(_ components: [String]) -> Bool {
            let key = components.joined(separator: "/")
            if let known = decided[key] { return known }
            let result =
                (components.count > 1 && folderIsIgnored(Array(components.dropLast())))
                || rules.matches(components, isFolder: true)
            decided[key] = result
            return result
        }
    }
}

/// One line of a `.gitignore` (or `.atdriveignore`), meaning exactly what git takes it to mean:
///
/// - Blank lines and lines starting with `#` are skipped; `\#` and `\!` start a pattern with a
///   literal `#` or `!`. Trailing spaces are dropped unless escaped with `\`.
/// - `!` brings back something an earlier pattern ignored.
/// - A trailing `/` matches folders only.
/// - A pattern with no other `/` matches a name at any depth; one with a `/` at the start or in
///   the middle matches a path relative to the ignore file's folder.
/// - `*` is anything but `/`, `?` one character but `/`, `[…]` one of a set (`[!…]` or `[^…]`
///   none of it; ranges; `[:alpha:]` and the other POSIX classes), `\` escapes a character.
/// - `**/` at the start or between slashes is any number of folders (none included), a trailing
///   `/**` everything inside; other runs of `*` are just `*`.
///
/// Matching is by Unicode scalar, and case-sensitive.
public struct IgnorePattern: Sendable, Equatable {
    public let negated: Bool
    /// A trailing `/`: folders only.
    public let foldersOnly: Bool
    /// No `/` (besides a trailing one): matched against the name alone.
    public let nameOnly: Bool
    private let tokens: [Token]

    enum Token: Sendable, Equatable {
        case literal(Unicode.Scalar)
        /// `?`
        case one
        /// `*`
        case star
        /// `**` with a slash or the end on both sides: `**/` is any number of folders, a final
        /// `**` anything at all.
        case globstar
        case set(CharacterSet)
    }

    struct CharacterSet: Sendable, Equatable {
        enum Member: Sendable, Equatable {
            case scalar(Unicode.Scalar)
            case range(Unicode.Scalar, Unicode.Scalar)
            case named(String)
        }
        var negated: Bool
        var members: [Member]

        func contains(_ c: Unicode.Scalar) -> Bool {
            members.contains { member in
                switch member {
                case .scalar(let s): c == s
                case .range(let low, let high): c >= low && c <= high
                case .named(let name): Self.isMember(c, of: name)
                }
            } != negated
        }

        static let classNames: Set<String> = [
            "alnum", "alpha", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper",
            "xdigit",
        ]

        /// The POSIX classes, for ASCII (as git has them).
        static func isMember(_ c: Unicode.Scalar, of name: String) -> Bool {
            guard c.isASCII else { return false }
            let v = c.value
            let isDigit = (0x30...0x39).contains(v)
            let isUpper = (0x41...0x5A).contains(v)
            let isLower = (0x61...0x7A).contains(v)
            let isGraph = (0x21...0x7E).contains(v)
            switch name {
            case "alnum": return isDigit || isUpper || isLower
            case "alpha": return isUpper || isLower
            case "blank": return v == 0x20 || v == 0x09
            case "cntrl": return v < 0x20 || v == 0x7F
            case "digit": return isDigit
            case "graph": return isGraph
            case "lower": return isLower
            case "print": return isGraph || v == 0x20
            case "punct": return isGraph && !(isDigit || isUpper || isLower)
            case "space": return v == 0x20 || (0x09...0x0D).contains(v)
            case "upper": return isUpper
            case "xdigit": return isDigit || (0x41...0x46).contains(v) || (0x61...0x66).contains(v)
            default: return false
            }
        }
    }

    /// Every pattern in an ignore file's text.
    public static func parse(_ text: String) -> [IgnorePattern] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = first.dropFirst() }
        return lines.compactMap { IgnorePattern(String($0)) }
    }

    /// One line; `nil` for a blank line, a comment, or a pattern that can never match (a set
    /// that isn't closed, a trailing `\`).
    public init?(_ line: String) {
        var scalars = Array(line.unicodeScalars)
        if scalars.last == "\r" { scalars.removeLast() }
        guard let first = scalars.first, first != "#" else { return nil }
        scalars = Self.trimmingTrailingSpaces(scalars)
        var negated = false
        if scalars.first == "!" {
            negated = true
            scalars.removeFirst()
        }
        var foldersOnly = false
        if scalars.last == "/" {
            foldersOnly = true
            scalars.removeLast()
        }
        guard !scalars.isEmpty else { return nil }
        let nameOnly = !scalars.contains("/")
        if !nameOnly, scalars.first == "/" { scalars.removeFirst() }
        guard let tokens = Self.compile(scalars) else { return nil }
        self.negated = negated
        self.foldersOnly = foldersOnly
        self.nameOnly = nameOnly
        self.tokens = tokens
    }

    /// Whether it matches something at `path` (relative to the ignore file's folder), named `name`.
    public func matches(path: String, name: String, isFolder: Bool) -> Bool {
        if foldersOnly, !isFolder { return false }
        return Self.match(tokens, Array((nameOnly ? name : path).unicodeScalars))
    }

    // MARK: Parsing

    /// Drops trailing spaces, but not one escaped with `\` (git's `trim_trailing_spaces`).
    private static func trimmingTrailingSpaces(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var end = 0  // just past the last thing to keep
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\" {
                index += 1
                end = min(index + 1, scalars.count)
            } else if scalars[index] != " " {
                end = index + 1
            }
            index += 1
        }
        return Array(scalars[..<end])
    }

    private static func compile(_ p: [Unicode.Scalar]) -> [Token]? {
        var tokens: [Token] = []
        var i = 0
        while i < p.count {
            let c = p[i]
            switch c {
            case "\\":
                guard i + 1 < p.count else { return nil }
                tokens.append(.literal(p[i + 1]))
                i += 2
            case "?":
                tokens.append(.one)
                i += 1
            case "*":
                var end = i
                while end < p.count, p[end] == "*" { end += 1 }
                let atStart = i == 0 || p[i - 1] == "/"
                let atEnd = end == p.count || p[end] == "/"
                if end - i >= 2, atStart, atEnd {
                    tokens.append(.globstar)
                } else if tokens.last != .star {
                    tokens.append(.star)
                }
                i = end
            case "[":
                guard let (set, next) = compileSet(p, from: i + 1) else { return nil }
                tokens.append(.set(set))
                i = next
            default:
                tokens.append(.literal(c))
                i += 1
            }
        }
        return tokens
    }

    /// A `[…]` set, from just after its `[`: the set and where the pattern goes on. `nil` if it
    /// isn't closed or names a class that doesn't exist (git never matches such a pattern).
    private static func compileSet(_ p: [Unicode.Scalar], from start: Int) -> (CharacterSet, Int)? {
        var i = start
        var negated = false
        if i < p.count, p[i] == "!" || p[i] == "^" {
            negated = true
            i += 1
        }
        var members: [CharacterSet.Member] = []
        // The last single character, which a following `-` makes the start of a range.
        var previous: Unicode.Scalar?
        var first = true
        while true {
            guard i < p.count else { return nil }
            let c = p[i]
            if c == "]", !first { return (CharacterSet(negated: negated, members: members), i + 1) }
            first = false
            if c == "\\" {
                guard i + 1 < p.count else { return nil }
                members.append(.scalar(p[i + 1]))
                previous = p[i + 1]
                i += 2
            } else if c == "-", let low = previous, i + 1 < p.count, p[i + 1] != "]" {
                var high = p[i + 1]
                i += 2
                if high == "\\" {
                    guard i < p.count else { return nil }
                    high = p[i]
                    i += 1
                }
                members.removeLast()  // `low`, now the start of the range
                members.append(.range(low, high))
                previous = nil
            } else if c == "[", i + 1 < p.count, p[i + 1] == ":" {
                // `[:name:]`, or just a `[` if there's no `:]` before the next `]`.
                var end = i + 2
                while end < p.count, p[end] != "]" { end += 1 }
                guard end < p.count else { return nil }
                if end - 1 >= i + 2, p[end - 1] == ":" {
                    let name = String(String.UnicodeScalarView(p[(i + 2)..<(end - 1)]))
                    guard CharacterSet.classNames.contains(name) else { return nil }
                    members.append(.named(name))
                    previous = nil
                    i = end + 1
                } else {
                    members.append(.scalar("["))
                    previous = "["
                    i += 1
                }
            } else {
                members.append(.scalar(c))
                previous = c
                i += 1
            }
        }
    }

    // MARK: Matching

    /// git's `wildmatch(pattern, text, WM_PATHNAME)`: the whole pattern against the whole text.
    static func wildmatch(_ pattern: String, _ text: String) -> Bool {
        guard let tokens = compile(Array(pattern.unicodeScalars)) else { return false }
        return match(tokens, Array(text.unicodeScalars))
    }

    private static func match(_ tokens: [Token], _ text: [Unicode.Scalar]) -> Bool {
        // Each (token, text position) is worked out once, so `*`s can't make it exponential.
        var known: [Int: Bool] = [:]
        let width = text.count + 1
        func at(_ t: Int, _ s: Int) -> Bool {
            if t == tokens.count { return s == text.count }
            let key = t * width + s
            if let result = known[key] { return result }
            let result: Bool
            switch tokens[t] {
            case .literal(let c):
                result = s < text.count && text[s] == c && at(t + 1, s + 1)
            case .one:
                result = s < text.count && text[s] != "/" && at(t + 1, s + 1)
            case .set(let set):
                result = s < text.count && text[s] != "/" && set.contains(text[s]) && at(t + 1, s + 1)
            case .star:
                var end = s
                while end < text.count, text[end] != "/" { end += 1 }
                result = (s...end).contains { at(t + 1, $0) }
            case .globstar:
                if t + 1 == tokens.count {
                    result = true
                } else {
                    // Followed by `/`: no folders, or anything up to and including a `/`.
                    result = at(t + 2, s) || (s..<text.count).contains { text[$0] == "/" && at(t + 2, $0 + 1) }
                }
            }
            known[key] = result
            return result
        }
        return at(0, 0)
    }
}

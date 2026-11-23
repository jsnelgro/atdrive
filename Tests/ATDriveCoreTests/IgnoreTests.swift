import Foundation
import Testing

@testable import ATDriveCore

/// `.gitignore`'s meaning, exactly: the matcher (cases from git's `t3070-wildmatch.sh`, with
/// `WM_PATHNAME`), the lines, and how the files combine.
@Suite struct IgnoreTests {
    // MARK: Wildmatch

    @Test(arguments: [
        // Literals, ?, *
        ("foo", "foo", true), ("bar", "foo", false), ("", "", true), ("???", "foo", true), ("??", "foo", false),
        ("*", "foo", true), ("f*", "foo", true), ("*f", "foo", false), ("*foo*", "foo", true),
        ("*ob*a*r*", "foobar", true), ("*ab", "aaaaaaabababab", true), ("foo\\*", "foo*", true),
        ("foo\\*bar", "foobar", false), ("f\\\\oo", "f\\oo", true), ("\\a\\b\\c", "abc", true),
        ("\\??\\?b", "?a?b", true), ("", "foo", false), ("foo", "", false),
        // Sets
        ("*[al]?", "ball", true), ("[ten]", "ten", false), ("**[!te]", "ten", true), ("**[!ten]", "ten", false),
        ("t[a-g]n", "ten", true), ("t[!a-g]n", "ten", false), ("t[!a-g]n", "ton", true), ("t[^a-g]n", "ton", true),
        ("a[]]b", "a]b", true), ("a[]-]b", "a-b", true), ("a[]-]b", "a]b", true), ("a[]-]b", "aab", false),
        ("a[]a-]b", "aab", true), ("]", "]", true), ("\\[ab]", "[ab]", true), ("[[]ab]", "[ab]", true),
        ("[[:]ab]", "[ab]", true), ("[[::]ab]", "[ab]", false), ("[[:digit]ab]", "[ab]", true),
        ("[\\[:]ab]", "[ab]", true), ("[", "[", false), ("[!", "a", false), ("a[", "a", false),
        ("[a-c]", "b", true), ("[\\a-\\c]", "b", true), ("[-a]", "-", true), ("[a-]", "-", true),
        // Classes
        ("[[:alpha:]][[:digit:]][[:upper:]]", "a1B", true), ("[[:digit:][:upper:][:space:]]", "a", false),
        ("[[:digit:][:upper:][:space:]]", "A", true), ("[[:digit:][:upper:][:space:]]", "1", true),
        ("[[:digit:][:upper:][:space:]]", " ", true), ("[[:xdigit:]]", "5", true), ("[[:xdigit:]]", "f", true),
        ("[[:xdigit:]]", "D", true), ("[[:xdigit:]]", "g", false), ("[[:punct:]]", ".", true),
        ("[[:nope:]]", "a", false),
        // Slashes
        ("foo*bar", "foo/baz/bar", false), ("foo**bar", "foo/baz/bar", false), ("foo**bar", "foobazbar", true),
        ("foo/**/bar", "foo/baz/bar", true), ("foo/**/**/bar", "foo/baz/bar", true),
        ("foo/**/bar", "foo/b/a/z/bar", true), ("foo/**/**/bar", "foo/b/a/z/bar", true),
        ("foo/**/bar", "foo/bar", true), ("foo/**/**/bar", "foo/bar", true), ("foo?bar", "foo/bar", false),
        ("foo[/]bar", "foo/bar", false), ("f[^eiu][^eiu][^eiu][^eiu][^eiu]r", "foo/bar", false),
        ("f[^eiu][^eiu][^eiu][^eiu][^eiu]r", "foo-bar", true), ("**/foo", "foo", true), ("**/foo", "XXX/foo", true),
        ("**/foo", "bar/baz/foo", true), ("*/foo", "bar/baz/foo", false), ("**/bar*", "foo/bar/baz", false),
        ("**/bar/*", "deep/foo/bar/baz", true), ("**/bar/*", "deep/foo/bar/baz/", false),
        ("**/bar/**", "deep/foo/bar/baz/", true), ("**/bar/*", "deep/foo/bar", false),
        ("**/bar/**", "deep/foo/bar/", true), ("**/bar**", "foo/bar/baz", false), ("*/bar/**", "foo/bar/baz/x", true),
        ("*/bar/**", "deep/foo/bar/baz/x", false), ("**/bar/*/*", "deep/foo/bar/baz/x", true),
        ("**/t[o]", "foo/bar/baz/to", true), ("abc/**", "abc", false), ("abc/**", "abc/x/y", true), ("**", "a/b", true),
        ("a/*", "a/b/c", false), ("*", "a/b", false),
    ])
    func wildmatch(pattern: String, text: String, expected: Bool) {
        #expect(IgnorePattern.wildmatch(pattern, text) == expected, "\(pattern) vs \(text)")
    }

    @Test func manyStarsStayFast() {
        let text = String(repeating: "a", count: 60)
        #expect(!IgnorePattern.wildmatch(String(repeating: "*a", count: 30) + "b", text))
    }

    // MARK: Lines

    func pattern(_ line: String) -> IgnorePattern? { IgnorePattern(line) }

    func matches(_ line: String, _ path: String, folder: Bool = false) -> Bool {
        guard let p = IgnorePattern(line) else { return false }
        return p.matches(path: path, name: String(path.split(separator: "/").last ?? ""), isFolder: folder)
    }

    @Test func blankLinesAndCommentsArentPatterns() {
        #expect(pattern("") == nil)
        #expect(pattern("   ") == nil)
        #expect(pattern("# a comment") == nil)
        #expect(pattern("!") == nil)
        #expect(pattern("/") == nil)
        #expect(matches("\\#file", "#file"))
        #expect(matches("\\!important", "!important"))
        #expect(pattern("\\!important")?.negated == false)
    }

    @Test func trailingSpacesAreDroppedUnlessEscaped() {
        #expect(matches("foo   ", "foo"))
        #expect(!matches("foo   ", "foo "))
        #expect(matches("foo\\ ", "foo "))
        #expect(matches("foo\\  ", "foo "))
        #expect(!matches(" foo", "foo"))  // leading spaces count
        #expect(matches("foo\r", "foo"))  // a file with Windows line endings
    }

    @Test func negationAndFolderOnly() throws {
        let negated = try #require(pattern("!keep.log"))
        #expect(negated.negated)
        let folder = try #require(pattern("build/"))
        #expect(folder.foldersOnly && folder.nameOnly)
        #expect(matches("build/", "x/build", folder: true))
        #expect(!matches("build/", "x/build", folder: false))
        #expect(!matches("trailing\\", "trailing\\"))  // an unescaped final backslash never matches
    }

    @Test func aSlashAnchorsToTheFilesFolder() {
        #expect(matches("*.log", "a/b/c.log"))  // no slash: any depth
        #expect(matches("/build", "build", folder: true))
        #expect(!matches("/build", "src/build", folder: true))
        #expect(matches("doc/*.txt", "doc/a.txt"))
        #expect(!matches("doc/*.txt", "doc/x/a.txt"))
        #expect(!matches("doc/*.txt", "x/doc/a.txt"))
        #expect(matches("doc/**/*.txt", "doc/x/y/a.txt"))
        #expect(matches("**/logs", "a/b/logs", folder: true))
    }

    @Test func parsesAFile() {
        let patterns = IgnorePattern.parse("\u{FEFF}# top\n*.o\r\n\n!keep.o\nbuild/\n")
        #expect(patterns.count == 3)
        #expect(patterns.map(\.negated) == [false, true, false])
    }

    // MARK: Combining

    @Test func theLastMatchWinsAndDeeperFilesWin() {
        var rules = IgnoreRules(IgnoreSettings())
        rules.add(folder: "", atdriveignore: nil, gitignore: "*.log\n")
        rules.add(folder: "sub", atdriveignore: nil, gitignore: "!keep.log\n")
        #expect(rules.matches("a.log", isFolder: false))
        #expect(rules.matches("keep.log", isFolder: false))
        #expect(rules.matches("sub/other.log", isFolder: false))
        #expect(!rules.matches("sub/keep.log", isFolder: false))
        #expect(!rules.matches("sub/deeper/keep.log", isFolder: false))
        #expect(!rules.matches("a.txt", isFolder: false))
        rules.add(folder: "", atdriveignore: nil, gitignore: "*.log\n!*.log\n")
        #expect(!rules.matches("a.log", isFolder: false))
    }

    @Test func atdriveignoreBeatsGitignoreInTheSameFolder() {
        var rules = IgnoreRules(IgnoreSettings())
        rules.add(folder: "", atdriveignore: "!.env\n", gitignore: ".env\nsecret.txt\n")
        #expect(!rules.matches(".env", isFolder: false))
        #expect(rules.matches("secret.txt", isFolder: false))
    }

    @Test func gitignoreCanBeTurnedOff() {
        var rules = IgnoreRules(IgnoreSettings(gitignore: false))
        rules.add(folder: "", atdriveignore: "*.tmp\n", gitignore: "*.log\n")
        #expect(!rules.matches("a.log", isFolder: false))
        #expect(rules.matches("a.tmp", isFolder: false))
    }

    @Test func globalPatternsComeLast() {
        var rules = IgnoreRules(IgnoreSettings(patterns: ["*.tmp", "/top-only", "cache/"]))
        #expect(rules.matches("x/y.tmp", isFolder: false))
        #expect(rules.matches("top-only", isFolder: false))
        #expect(!rules.matches("x/top-only", isFolder: false))
        #expect(rules.matches("x/cache", isFolder: true))
        rules.add(folder: "x", atdriveignore: "!keep.tmp\n", gitignore: nil)
        #expect(!rules.matches("x/keep.tmp", isFolder: false))
        #expect(rules.matches("keep.tmp", isFolder: false))
    }

    @Test func patternsAreRelativeToTheirFolder() {
        var rules = IgnoreRules(IgnoreSettings())
        rules.add(folder: "app", atdriveignore: "/build\nsrc/*.gen\n", gitignore: nil)
        #expect(rules.matches("app/build", isFolder: true))
        #expect(!rules.matches("app/lib/build", isFolder: true))
        #expect(!rules.matches("build", isFolder: true))
        #expect(rules.matches("app/src/a.gen", isFolder: false))
        #expect(!rules.matches("src/a.gen", isFolder: false))
    }

    @Test func nothingInAnIgnoredFolderComesBack() {
        var rules = IgnoreRules(IgnoreSettings())
        rules.add(folder: "", atdriveignore: "build/\n!build/keep.txt\n", gitignore: nil)
        var lookup = IgnoreRules.Lookup(rules)
        let answers = [
            lookup.isIgnored(["build"], isFolder: true),
            lookup.isIgnored(["build", "keep.txt"], isFolder: false),
            lookup.isIgnored(["build", "a", "b.txt"], isFolder: false),
            lookup.isIgnored(["src", "build.txt"], isFolder: false),
            // A file called build isn't a folder.
            lookup.isIgnored(["build"], isFolder: false),
        ]
        #expect(answers == [true, true, true, false, false])
    }

    @Test func noRulesIgnoreNothing() {
        let rules = IgnoreRules(.none)
        #expect(rules.isEmpty)
        #expect(!rules.matches("anything", isFolder: false))
    }

    @Test func findsTheIgnoreFilesAboveAFolderInTheDrive() {
        func node(_ id: String, _ name: String, parent: String? = nil, folder: Bool = false) -> Node {
            Node(
                id: id, cid: "cid-\(id)",
                record: NodeRecord(name: name, parent: parent, kind: folder ? .folder : .file, size: 1))
        }
        let tree = DriveTree([
            node("top-ignore", ".atdriveignore"),
            node("top-git", ".gitignore"),
            node("a", "a", folder: true),
            node("b", "b", parent: "a", folder: true),
            node("b-ignore", ".atdriveignore", parent: "b"),
            node("odd", ".gitignore", parent: "a", folder: true),  // a folder: not an ignore file
        ])
        let files = IgnoreRules.files(for: "b", in: tree, settings: IgnoreSettings())
        #expect(files.map(\.folder) == ["", "a", "a/b"])
        #expect(files.map(\.atdriveignore?.id) == ["top-ignore", nil, "b-ignore"])
        #expect(files.map(\.gitignore?.id) == ["top-git", nil, nil])
        let withoutGit = IgnoreRules.files(for: nil, in: tree, settings: IgnoreSettings(gitignore: false))
        #expect(withoutGit.map(\.folder) == [""])
        #expect(withoutGit.first?.gitignore == nil)
    }

    @Test func readsIgnoreFilesFromDisk() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("*.a\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("*.b\n".utf8).write(to: root.appendingPathComponent("sub/.atdriveignore"))
        var rules = IgnoreRules(IgnoreSettings())
        rules.read(folder: "", in: root.path)
        rules.read(folder: "sub", in: root.path)
        #expect(rules.matches("x.a", isFolder: false))
        #expect(rules.matches("sub/x.b", isFolder: false))
        #expect(!rules.matches("x.b", isFolder: false))
        // Told what's in the folder, it doesn't look for anything else.
        var told = IgnoreRules(IgnoreSettings())
        told.read(folder: "", in: root.path, names: ["sub"])
        #expect(!told.matches("x.a", isFolder: false))
    }
}

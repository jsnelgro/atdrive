import ATDriveCore
import ArgumentParser
import Foundation

struct Share: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Share a file or folder with people, or, naming nobody, with a public link.",
        discussion: """
            atdrive share /photos alice.bsky.social bob.example.com   share it with them
            atdrive share /photos                                     a link anyone can open
            atdrive unshare /photos bob.example.com                   take bob off
            atdrive unshare /photos                                   stop sharing it

            People you share with can see it, read-only, and it's kept up to date for them. Naming nobody turns on a link anyone can open (and prints it again if it's on already). It stays right where it is in your drive.

            An encrypted drive's shares are encrypted, so whoever runs a PDS can't read them, even behind a link: the link ends with #<key>, and anyone with the whole link can read it.

            Sharing with people leaves it waiting for them: they accept it (`atdrive accept`, or the Mac app's menu) and it's added to their drive. You can also send them its link: `atdrive accept <link>` puts it in their drive, `atdrive get <link>` downloads a copy.
            """)

    @Argument(help: "File or folder in your drive.")
    var path: String

    @Argument(help: "Handles or DIDs to share it with (none: a public link).")
    var people: [String] = []

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() async throws {
        let joined = try await Context.load().joined
        let path = DrivePath(path)
        let snapshot = try await joined.update(nil)
        guard let node = try snapshot.tree.locate(path) else { throw SharingError.cantShareRoot }
        var mount = node
        if node.isMount {
            guard snapshot.mounts[node.id]?.readOnly == false else { throw SharingError.notYours(path.description) }
        } else {
            Output.status("Sharing \(path)…")
            mount = try await joined.share(node)
            Output.clearStatus()
        }

        guard !people.isEmpty else {
            let address = try await joined.turnLinkOn(mount)
            print("✓ Anyone with this link can see \(path):")
            print("  \(address)")
            if address.key != nil { print("  (the part after # is its key: keep the link whole)") }
            return
        }
        var dids: [String] = []
        for person in people { dids.append(try await Handles.did(person)) }
        let warnings = try await joined.memberWarnings(dids, for: mount)
        for warning in warnings { Output.warn(await Handles.describe(warning)) }
        if warnings.contains(where: { if case .keyChanged = $0 { true } else { false } }), !yes,
            !Prompt.confirm("Share with them anyway?")
        {
            print("Not shared with anyone new.")
            return
        }
        let failures = try await joined.addMembers(dids, to: mount, allowingChangedKeys: true)
        print("✓ Shared \(path) with \(people.joined(separator: ", ")).")
        let told = dids.filter { did in !failures.contains { $0.did == did } }
        if !told.isEmpty {
            print("  It's waiting for them to accept (`atdrive accept`, or ATDrive's menu on a Mac).")
        }
        for failure in failures {
            Output.warn("couldn't tell \(await Handles.name(failure.did)) about it: \(failure.reason)")
        }
        print("  Its link, if they'd rather open it that way:")
        print("  \(ShareLinkAddress(space: mount.record.mount!.space))")
    }
}

struct Unshare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take people off a share, or, naming nobody, stop sharing it.",
        discussion: """
            Naming people takes them off; it stays shared with the rest. Naming nobody stops sharing it with anyone, and turns its link off.

            Once nobody has it, it's an ordinary file or folder again, where it is in your drive (sharing it again makes a new link). What people already downloaded stays theirs.
            """)

    @Argument(help: "The share.")
    var path: String

    @Argument(help: "Handles or DIDs to take off (none: everyone, and the link).")
    var people: [String] = []

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() async throws {
        let joined = try await Context.load().joined
        let path = DrivePath(path)
        let snapshot = try await joined.update(nil)
        guard let mount = try snapshot.tree.locate(path), mount.isMount else {
            throw SharingError.notShared(path.description)
        }
        guard let share = try await joined.ownShares(in: snapshot).first(where: { $0.mount.id == mount.id }) else {
            throw SharingError.notYours(path.description)
        }

        if !people.isEmpty {
            var dids: [String] = []
            for person in people { dids.append(try await Handles.did(person)) }
            try await joined.removeMembers(dids, from: mount)
            print("✓ \(people.joined(separator: ", ")) no longer \(people.count == 1 ? "has" : "have") \(path).")
            let left = share.members.filter { !dids.contains($0.did) }
            guard left.isEmpty, !share.hasLink else { return }
            // Nobody has it now: an ordinary file or folder again.
            try await joined.unshare(mount)
            print("  Nobody else has it now, so it isn't shared any more.")
            return
        }

        let who = await Self.whoHasIt(share)
        print("Stop sharing \(path)? \(who.isEmpty ? "Nobody has it yet." : "\(who) will lose it.")")
        guard try yes || Output.confirm("Stop sharing it?") else { return }
        try await joined.unshare(mount)
        print("✓ \(path) isn't shared any more.")
    }

    /// "@alice, @bob and anyone with its link".
    static func whoHasIt(_ share: OwnShare) async -> String {
        var names: [String] = []
        for member in share.members { names.append(await Handles.name(member.did)) }
        if share.hasLink { names.append("anyone with its link") }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

struct Shares: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What you share (with whom, and its link), and what's shared with you.")

    @Argument(help: "One share (default: all of them).")
    var path: String?

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        var mine = try await joined.ownShares(in: snapshot)
        var theirs = joined.sharedWithMe(in: snapshot)
        var waiting: [PendingShare] = []
        if path == nil {
            do {
                waiting = try await joined.pendingShares()
            } catch {
                Output.warn("couldn't check for shares waiting for you: \(error)")
            }
        }
        if !waiting.isEmpty {
            print("Waiting for you (`atdrive accept`, `atdrive decline`):")
            for (index, share) in waiting.enumerated() {
                print("  \(await Pending.describe(share, number: index + 1))")
            }
            print("")
        }
        if let path {
            let path = DrivePath(path)
            mine = mine.filter { $0.path == path }
            theirs = theirs.filter { snapshot.tree.path(of: $0.mount) == path }
            if mine.isEmpty && theirs.isEmpty { throw SharingError.notShared(path.description) }
        }

        if path == nil || !mine.isEmpty {
            print("Shared by you:")
            if mine.isEmpty { print("  nothing (`atdrive share <path> [people…]`)") }
            for share in mine {
                print("  \(share.path)\(share.mode == .encrypted ? "" : "  (not encrypted)")")
                for member in try await joined.members(of: share.mount) {
                    var notes: [String] = []
                    if let fingerprint = member.fingerprint {
                        notes.append("key \(fingerprint)\(member.verified ? ", verified" : "")")
                    }
                    if member.protected == false { notes.append("their drive isn't encrypted") }
                    if member.keyChanged { notes.append("their key changed: share with them again for new files") }
                    let note = notes.isEmpty ? "" : "  (\(notes.joined(separator: "; ")))"
                    print("    \(await Handles.name(member.did))\(note)")
                }
                if share.hasLink, let link = try await joined.link(of: share.mount) {
                    print("    anyone with the link: \(link)")
                }
            }
        }
        if path == nil || !theirs.isEmpty {
            if path == nil { print("") }
            print("Shared with you:")
            if theirs.isEmpty { print("  nothing (`atdrive accept`)") }
            for (mount, state) in theirs {
                let status = state.problem.map { "  (can't read it: \($0))" } ?? ""
                print("  \(snapshot.tree.path(of: mount))  from \(await Handles.name(state.owner))\(status)")
            }
        }
    }
}

struct Accept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add something shared with you to your drive: one waiting for you, or from its link.",
        discussion: """
            atdrive accept                          go through what's waiting for you
            atdrive accept 1 3                      accept those (numbered as `atdrive accept` lists them)
            atdrive accept photos                   accept it by name
            atdrive accept --all                    accept everything waiting for you
            atdrive accept 'atdrive://open?at=…'    from a link someone sent you

            It's added at the top of your drive, read-only, under its owner's name for it, and kept up to date. You can move it anywhere in your drive. `atdrive rm` takes it out of your drive again (it stays shared with you). To download a copy instead: `atdrive get <link>`.
            """)

    @Argument(help: "What to accept: numbers or names from the list of what's waiting for you, or links.")
    var shares: [String] = []

    @Flag(name: .shortAndLong, help: "Accept everything waiting for you.")
    var all = false

    func run() async throws {
        let context = try await Context.load()
        let joined = context.joined
        let links = try shares.filter(Pending.isLink).map { try ShareLinkAddress(parsing: $0) }
        for link in links {
            let mount = try await joined.add(link)
            print("✓ Added /\(mount.name), shared by \(await Handles.name(mount.record.mount!.owner)), read-only.")
            if link.key != nil, context.drive.mode == .plain {
                Output.warn(
                    "your drive isn't encrypted, so its link key is kept readable: whoever runs your PDS could read this share"
                )
            }
        }
        let selectors = shares.filter { !Pending.isLink($0) }
        guard all || !selectors.isEmpty || links.isEmpty else { return }

        let waiting = try await joined.pendingShares()
        guard !waiting.isEmpty else {
            print(links.isEmpty ? "Nothing is waiting for you." : "Nothing else is waiting for you.")
            return
        }
        if all || !selectors.isEmpty {
            for share in all ? waiting : try Pending.pick(selectors, from: waiting) {
                try await Self.accept(share, in: joined)
            }
            return
        }
        // One by one.
        guard Prompt.isInteractive else {
            print("Waiting for you:")
            for (index, share) in waiting.enumerated() {
                print("  \(await Pending.describe(share, number: index + 1))")
            }
            print("Accept with `atdrive accept <number>` (or --all), or say no with `atdrive decline <number>`.")
            return
        }
        for (index, share) in waiting.enumerated() {
            print(await Pending.describe(share, number: index + 1))
            let answer = Prompt.line("  Add it to your drive? [y]es, [n]ot now, [d]ecline, [q]uit: ")?
                .trimmingCharacters(in: .whitespaces).lowercased()
            switch answer?.first {
            case "y": try await Self.accept(share, in: joined)
            case "d":
                try await joined.decline(share)
                print("  Declined.")
            case "q", nil: return
            default: continue
            }
        }
    }

    static func accept(_ share: PendingShare, in joined: JoinedDrive) async throws {
        if let problem = share.problem {
            throw ValidationError("\(await Pending.describe(share)) can't be opened now: \(problem)")
        }
        let mount = try await joined.accept(share)
        print("✓ Added /\(mount.name), shared by \(await Handles.name(share.owner)), read-only.")
    }
}

struct Decline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Say no to something shared with you: it stops waiting for you.",
        discussion: """
            Its owner isn't told, and it's still shared with you: its link still opens it (`atdrive accept <link>`).
            """)

    @Argument(help: "Numbers or names from the list of what's waiting for you (`atdrive accept` shows it).")
    var shares: [String]

    func run() async throws {
        let joined = try await Context.load().joined
        let waiting = try await joined.pendingShares()
        for share in try Pending.pick(shares, from: waiting) {
            try await joined.decline(share)
            print("✓ Declined \(await Pending.describe(share)).")
        }
    }
}

/// `atdrive open-share <link>`, from before `accept` took links: kept, hidden, so scripts that
/// use it keep working.
struct OpenShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-share", abstract: "Put something shared with you into your drive, from its link.",
        shouldDisplay: false)

    @Argument(help: "An atdrive:// link (or an at:// address).")
    var link: String

    func run() async throws {
        try await Accept.parse([link]).run()
    }
}

/// Shares waiting for this account, for the commands.
enum Pending {
    /// A link (or an `at://` address), rather than a number or name from the list.
    static func isLink(_ text: String) -> Bool { text.contains("://") }

    /// `1. photos/  from @alice.bsky.social, Nov 20`, and why it can't be opened, if it can't.
    static func describe(_ share: PendingShare, number: Int? = nil) async -> String {
        var line = number.map { "\($0). " } ?? ""
        line += share.name.map { $0 + (share.isFile ? "" : "/") } ?? "(something)"
        line += "  from \(await Handles.name(share.owner))"
        if let sent = share.sentAt { line += ", \(sent.formatted(date: .abbreviated, time: .omitted))" }
        if let problem = share.problem { line += "  (can't open it now: \(problem))" }
        return line
    }

    /// The shares `selectors` name: numbers (from 1, as listed) or names.
    static func pick(_ selectors: [String], from waiting: [PendingShare]) throws -> [PendingShare] {
        var picked: [PendingShare] = []
        for selector in selectors {
            let share: PendingShare
            if let number = Int(selector) {
                guard waiting.indices.contains(number - 1) else {
                    throw ValidationError("there's no number \(number): \(waiting.count) waiting for you")
                }
                share = waiting[number - 1]
            } else {
                let name = selector.hasSuffix("/") ? String(selector.dropLast()) : selector
                let named = waiting.filter { $0.name == name }
                guard let first = named.first else {
                    throw ValidationError("nothing called \(selector) is waiting for you")
                }
                guard named.count == 1 else {
                    throw ValidationError("\(named.count) called \(selector) are waiting for you: use their numbers")
                }
                share = first
            }
            if !picked.contains(share) { picked.append(share) }
        }
        return picked
    }
}

/// Downloads what a link shares, once (`atdrive get <link>`). Works signed out for a public link.
enum LinkDownload {
    static func run(_ text: String, to destination: URL) async throws {
        let link = try ShareLinkAddress(parsing: text)
        let context = try? await Context.load()
        let access =
            context.map { SpaceAccess(ownClient: $0.drive.client, resolver: IdentityResolver()) }
            ?? SpaceAccess(ownClient: nil, resolver: IdentityResolver())
        let keys = try? await context?.drive.settings()?.sharingKeyPair(encrypted: context?.drive.mode == .encrypted)
        let opened = try await JoinedDrive.open(link, access: access, sharingKeys: keys, me: context?.drive.owner)
        let root = try await opened.download(
            into: destination,
            each: { _, file in
                Output.clearStatus()
                print("↓ \(file.relativePath)")
            }, progress: { Output.progress("↓", $0) })
        print("✓ Downloaded \(opened.name), shared by \(await Handles.name(opened.owner)), to \(root.relativePath)")
    }
}

/// Handles and DIDs, for showing people and finding them.
enum Handles {
    static func did(_ person: String) async throws -> String {
        if person.hasPrefix("did:") { return person }
        return try await IdentityResolver().resolve(person).did
    }

    /// `@handle`, or the DID if it has none.
    static func name(_ did: String) async -> String {
        (try? await IdentityResolver().resolve(did).handle).map { "@\($0)" } ?? did
    }

    static func describe(_ warning: MemberWarning) async -> String {
        switch warning {
        case .unprotected(let did):
            "\(await name(did))'s drive isn't encrypted, so whoever runs their PDS could read this share"
        case .keyChanged(let did, let from, let to):
            "\(await name(did))'s sharing key changed (\(from) → \(to)). If you didn't expect that, compare "
                + "verification codes first (`atdrive verify \(await name(did))`)"
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check someone's sharing key with a code you both compare.",
        discussion: """
            Encrypted shares are wrapped for the sharing key each person publishes, which is only as trustworthy as their PDS. To be sure it's theirs, both of you run this, and compare the codes over something you trust (in person, or a call). If they match, you mark each other as verified, on all your devices.

            If their key changes later (a new setup, or a PDS putting in a key of its own), they're no longer verified, and you're asked before anything new is shared with them.
            """)

    @Argument(help: "Their handle or DID.")
    var person: String

    func run() async throws {
        let joined = try await Context.load().joined
        let did = try await Handles.did(person)
        let (code, theirs) = try await joined.verificationCode(with: did)
        let name = await Handles.name(did)
        if try await joined.isVerified(did, key: theirs) {
            print("\(name) is verified: their sharing key is the one you checked. Code: \(code)")
            return
        }
        print(
            """
            Your verification code with \(name):

              \(code)

            Ask them to run `atdrive verify` with your handle, and compare: the same code on
            both sides means you each have the other's real key.
            """)
        if !theirs.protected {
            print("Note: \(name)'s drive isn't encrypted, so their PDS could still read what you share with them.")
        }
        guard Prompt.confirm("Do your codes match?") else {
            print(
                "Not verified. If the codes differ, someone may be putting in a key of their own: don't share encrypted files with \(name) until they match."
            )
            return
        }
        try await joined.markVerified(did, key: theirs)
        print("✓ \(name) is verified.")
    }
}

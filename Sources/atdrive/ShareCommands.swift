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

            Links look like atdrive://open?at=…: `atdrive open-share <link>` puts it in your drive, `atdrive get <link>` downloads a copy.
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
        try await joined.addMembers(dids, to: mount, allowingChangedKeys: true)
        print("✓ Shared \(path) with \(people.joined(separator: ", ")). Send them this link to open it:")
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
            if theirs.isEmpty { print("  nothing (`atdrive open-share <link>`)") }
            for (mount, state) in theirs {
                let status = state.problem.map { "  (can't read it: \($0))" } ?? ""
                print("  \(snapshot.tree.path(of: mount))  from \(await Handles.name(state.owner))\(status)")
            }
        }
    }
}

struct OpenShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-share", abstract: "Put something shared with you into your drive, from its link.",
        discussion: """
            It's added at the top of your drive, under its name, read-only, and kept up to date. `atdrive rm` takes it out of your drive again (it stays shared). To download a copy instead: `atdrive get <link>`.
            """)

    @Argument(help: "An atdrive:// link (or an at:// address).")
    var link: String

    func run() async throws {
        let link = try ShareLinkAddress(parsing: link)
        let context = try await Context.load()
        let mount = try await context.joined.add(link)
        let owner = await Handles.name(mount.record.mount!.owner)
        print("✓ Added /\(mount.name), shared by \(owner), read-only.")
        if link.key != nil, context.drive.mode == .plain {
            Output.warn(
                "your drive isn't encrypted, so its link key is kept readable: whoever runs your PDS could read this share"
            )
        }
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

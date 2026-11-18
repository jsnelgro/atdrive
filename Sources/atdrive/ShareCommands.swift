import ATDriveCore
import ArgumentParser
import Foundation

struct Share: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Share a file or folder: with people, or with anyone who has its link. Read-only.",
        discussion: """
            atdrive share /photos --link              anyone with the link can see it
            atdrive share /photos --with alice.bsky.social --with bob.example.com
            atdrive share ls                          what you share, and with whom
            atdrive share remove /photos bob.example.com
            atdrive unshare /photos                   stop sharing it with anyone

            The first time something is shared, it moves into a space of its own, which stays where it was in your drive. It keeps its files; its history up to now stays in your drive's history, and people you share it with see it from now on.

            Shares take your drive's mode: an encrypted drive's shares are encrypted, so whoever runs a PDS can't read them, even behind a link. --plain makes an unencrypted share from an encrypted drive.

            Links look like atdrive://open?at=…, and open in ATDrive (`atdrive open <link>`). An encrypted share's link ends with #<key>: anyone with the whole link can read it.
            """,
        subcommands: [ShareAdd.self, ShareList.self, ShareRemove.self, ShareLink.self, ShareVerify.self],
        defaultSubcommand: ShareAdd.self)
}

struct ShareAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Share a file or folder (the default: `atdrive share <path> …`).")

    @Argument(help: "File or folder in your drive.")
    var path: String

    @Option(name: .customLong("with"), help: "Someone to share it with: a handle or DID. Repeat for more.")
    var people: [String] = []

    @Flag(help: "Turn its link on: anyone who has it can see what's shared.")
    var link = false

    @Flag(help: "Turn its link off.")
    var noLink = false

    @Flag(help: "From an encrypted drive: share it unencrypted, readable by whoever runs your PDS.")
    var plain = false

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func validate() throws {
        if link && noLink { throw ValidationError("choose --link or --no-link") }
    }

    func run() async throws {
        let context = try await Context.load()
        let joined = context.joined
        let path = DrivePath(path)
        var snapshot = try await joined.update(nil)
        guard let node = try snapshot.tree.locate(path) else { throw SharingError.cantShareRoot }
        var mount = node
        if node.isMount {
            guard snapshot.mounts[node.id]?.readOnly == false else {
                throw SharingError.notYours(path.description)
            }
            if plain { Output.warn("\(path) is already shared; --plain only applies when it's first shared") }
        } else {
            if plain {
                guard context.drive.mode == .encrypted else {
                    throw ValidationError(
                        "your drive isn't encrypted, so its shares aren't either: --plain isn't needed")
                }
                print(
                    "\(path) will be shared unencrypted: whoever runs your PDS can read it, and its files are uploaded again."
                )
                guard yes || Prompt.confirm("Share it unencrypted?") else { return }
            }
            Output.status("Moving \(path) into a space of its own…")
            mount = try await joined.share(node, plain: plain)
            Output.clearStatus()
            print("✓ \(path) is in a space of its own, ready to share.")
            snapshot = try await joined.update(snapshot)
        }

        if !people.isEmpty {
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
        if link {
            let address = try await joined.turnLinkOn(mount)
            print("✓ Its link is on. Anyone who has it can see \(path):")
            print("  \(address)")
            if address.key != nil { print("  (the part after # is its key: keep the link whole, and keep it private)") }
        }
        if noLink {
            try await joined.turnLinkOff(mount)
            print("✓ Its link is off. People who opened it keep what they already have.")
        }
        if people.isEmpty && !link && !noLink {
            print("Share it: atdrive share \(path) --link, or --with <handle>")
        }
    }
}

struct ShareList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "What you share: each share's mode, link, and who has it.")

    @Argument(help: "A share (default: all of them).")
    var path: String?

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        var shares = try await joined.ownShares(in: snapshot)
        if let path {
            shares = shares.filter { $0.path == DrivePath(path) }
            if shares.isEmpty { throw SharingError.notShared(DrivePath(path).description) }
        }
        if shares.isEmpty {
            print("You don't share anything. (`atdrive share <path> --link` or `--with <handle>`)")
            return
        }
        for share in shares {
            let mode = share.mode == .encrypted ? "encrypted" : "not encrypted"
            let link = share.hasLink ? "link on" : "no link"
            print("\(share.path)  (\(mode), \(link))")
            let members = try await joined.members(of: share.mount)
            if members.isEmpty, !share.hasLink { print("  not shared with anyone yet") }
            for member in members {
                var notes: [String] = []
                if let fingerprint = member.fingerprint {
                    notes.append("key \(fingerprint)\(member.verified ? ", verified" : "")")
                }
                if member.protected == false { notes.append("their drive isn't encrypted") }
                if member.keyChanged { notes.append("their key changed: add them again to give them new files") }
                let note = notes.isEmpty ? "" : "  (\(notes.joined(separator: "; ")))"
                print("  \(await Handles.name(member.did))\(note)")
            }
        }
    }
}

struct ShareRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Stop sharing something with some people.")

    @Argument(help: "The share.")
    var path: String

    @Argument(help: "Handles or DIDs.")
    var people: [String]

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        guard let mount = try snapshot.tree.locate(DrivePath(path)), mount.isMount else {
            throw SharingError.notShared(DrivePath(path).description)
        }
        var dids: [String] = []
        for person in people { dids.append(try await Handles.did(person)) }
        try await joined.removeMembers(dids, from: mount)
        print("✓ \(people.joined(separator: ", ")) no longer \(people.count == 1 ? "has" : "have") \(DrivePath(path)).")
        print("  What they already downloaded stays theirs; they get nothing new.")
    }
}

struct ShareLink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Show a share's link.")

    @Argument(help: "The share.")
    var path: String

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        guard let mount = try snapshot.tree.locate(DrivePath(path)), mount.isMount,
            let info = mount.record.mount
        else { throw SharingError.notShared(DrivePath(path).description) }
        if let link = try await joined.link(of: mount) {
            print(link)
        } else {
            // Members (and, for someone else's share, you) open it with the address alone.
            print(ShareLinkAddress(space: info.space))
            if info.owner == joined.owner {
                Output.warn("its link is off: only people you share it with can open this")
            }
        }
    }
}

struct Unshare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop sharing a file or folder with anyone.",
        discussion: """
            Removes everyone you shared it with and turns its link off. It stays where it is in your drive, an ordinary file or folder again (sharing it again makes a new link). What people already downloaded stays theirs.
            """)

    @Argument(help: "The share.")
    var path: String

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        guard let mount = try snapshot.tree.locate(DrivePath(path)), mount.isMount else {
            throw SharingError.notShared(DrivePath(path).description)
        }
        guard yes || Prompt.confirm("Stop sharing \(DrivePath(path)) with everyone?") else { return }
        try await joined.unshare(mount)
        print("✓ \(DrivePath(path)) isn't shared any more.")
    }
}

// MARK: Shared with you

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add something shared with you to your drive, from its link.",
        discussion: """
            It's added at the top of your drive, under its name, read-only, and kept up to date. Same as `atdrive shared add`.
            """)

    @Argument(help: "An atdrive:// link (or an at:// address).")
    var link: String

    func run() async throws { try await SharedAdd.add(link) }
}

struct Shared: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What other people shared with you, in your drive.",
        subcommands: [SharedList.self, SharedAdd.self, SharedRemove.self], defaultSubcommand: SharedList.self)
}

struct SharedAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a share from its link.")

    @Argument(help: "An atdrive:// link (or an at:// address).")
    var link: String

    func run() async throws { try await Self.add(link) }

    static func add(_ text: String) async throws {
        let link = try ShareLinkAddress(parsing: text)
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

struct SharedList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Shares other people added you to, or you opened.")

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        let shared = joined.sharedWithMe(in: snapshot)
        if shared.isEmpty {
            print("Nothing shared with you is in your drive. (`atdrive open <link>`)")
            return
        }
        for (mount, state) in shared {
            let mode = state.mode.map { $0 == .encrypted ? "encrypted" : "not encrypted" } ?? "?"
            let status = state.problem.map { "can't read it: \($0)" } ?? "up to date"
            print("\(snapshot.tree.path(of: mount))  from \(await Handles.name(state.owner))  (\(mode); \(status))")
        }
    }
}

struct SharedRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove a share from your drive (it stays shared; you just stop seeing it).")

    @Argument(help: "Its path in your drive.")
    var path: String

    func run() async throws {
        let joined = try await Context.load().joined
        let snapshot = try await joined.update(nil)
        guard let mount = try snapshot.tree.locate(DrivePath(path)), mount.isMount,
            snapshot.mounts[mount.id]?.readOnly == true
        else { throw ValidationError("\(DrivePath(path)) isn't something shared with you") }
        try await joined.delete([mount])
        print("✓ Removed \(DrivePath(path)) from your drive.")
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
                + "verification codes first (`atdrive share verify \(await name(did))`)"
        }
    }
}

struct ShareVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Check someone's sharing key with a code you both compare.",
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

            Ask them to run `atdrive share verify` with your handle, and compare: the same code on
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

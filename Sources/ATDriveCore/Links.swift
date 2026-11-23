import Foundation

// Links (PLAN.md, "Links"): `atdrive://open?at=<the space's at:// address>`, with `#<link key>`
// for an encrypted share's public link. Nothing is hosted: opening one takes ATDrive. The link
// key is in the fragment, so it never reaches a server, and the CLI never logs it.

/// A link to a shared space.
public struct ShareLinkAddress: Sendable, Equatable, CustomStringConvertible {
    /// `at://<authority>/space/<type>/<key>`.
    public var space: String
    /// An encrypted share's link key, from the fragment.
    public var key: Data?

    public init(space: String, key: Data? = nil) {
        self.space = space
        self.key = key
    }

    /// Reads `atdrive://open?at=…[#key]`, or a bare `at://` space address (with or without
    /// `#key`).
    public init(parsing text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fragment: String?
        var base = text
        if let hash = text.firstIndex(of: "#") {
            fragment = String(text[text.index(after: hash)...])
            base = String(text[..<hash])
        }
        var space: String
        if base.hasPrefix("at://") {
            space = base
        } else if base.hasPrefix("atdrive://"), let components = URLComponents(string: base),
            components.host == "open" || components.path == "open" || components.path == "/open",
            let at = components.queryItems?.first(where: { $0.name == "at" })?.value
        {
            space = at
        } else {
            throw ATDriveError.invalidLink(text)
        }
        while space.hasSuffix("/") { space.removeLast() }
        guard XRPCClient.spaceParts(space) != nil else { throw ATDriveError.invalidLink(text) }
        self.space = space
        if let fragment, !fragment.isEmpty {
            guard let key = Base64URL.decode(fragment), key.count == 32 else { throw SharingError.linkKeyWrong }
            self.key = key
        }
    }

    /// The `atdrive://` link.
    public var description: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=#+")
        let at = space.addingPercentEncoding(withAllowedCharacters: allowed) ?? space
        return "atdrive://open?at=\(at)" + (key.map { "#" + Base64URL.encode($0) } ?? "")
    }

    /// Whether it's a link to an ATDrive drive (rather than to another app's space).
    public var isDrive: Bool { XRPCClient.spaceParts(space)?.type == Lexicon.driveSpace }
}

/// What a link opens to, before it's added: what's shared, by whom, how.
public struct OpenedShare: Sendable {
    public var link: ShareLinkAddress
    public var owner: String
    /// The shared file's or folder's name.
    public var name: String
    public var mode: DriveMode
    /// One file (`DriveSettings.file`), not a folder.
    public var isFile: Bool
    /// The share, opened: read its tree, download it.
    public var drive: Drive

    /// Downloads it into `folder`: a shared file as the file, a folder as a folder of its name.
    /// `each` hears about every file once it's written. Returns what was made.
    @discardableResult
    public func download(
        into folder: URL, each: (DrivePath, URL) -> Void = { _, _ in },
        progress: (DrivePath) -> Drive.Progress? = { _ in nil }
    ) async throws -> URL {
        let tree = try await drive.tree()
        let root = folder.appendingPathComponent(name)
        let top = tree.children(of: nil)
        if isFile, top.count == 1, let file = top.first, !file.isFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await drive.download(file, to: root, progress: progress(.root.appending(name)))
            each(.root.appending(name), root)
            return root
        }
        try await download(nil, in: tree, to: root, at: .root.appending(name), each: each, progress: progress)
        return root
    }

    private func download(
        _ parent: String?, in tree: DriveTree, to local: URL, at path: DrivePath, each: (DrivePath, URL) -> Void,
        progress: (DrivePath) -> Drive.Progress?
    ) async throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for child in tree.children(of: parent) {
            let target = local.appendingPathComponent(child.name)
            let childPath = path.appending(child.name)
            if child.isFolder {
                try await download(child.id, in: tree, to: target, at: childPath, each: each, progress: progress)
            } else {
                try await drive.download(child, to: target, progress: progress(childPath))
                each(childPath, target)
            }
        }
    }
}

extension JoinedDrive {
    // MARK: The owner's side

    /// Turns a share's public link on: anyone with the link can read it. An encrypted share gets
    /// a link record, its keyring sealed with a new link key (kept in the mount, sealed in the
    /// drive, so the link can be shown again). Returns the link. Already on: the same link.
    @discardableResult
    public func turnLinkOn(_ mount: Node) async throws -> ShareLinkAddress {
        let mount = try await current(mount)
        let (info, share) = try await ownShare(mount)
        var linkKey = info.linkKey?.data
        if let keyring = share.keyring {
            if linkKey == nil {
                let key = ShareLink.newKey()
                let value = try ShareLink.record(for: keyring, linkKey: key, space: info.space)
                do {
                    try await share.apply([.create(collection: Lexicon.link, rkey: Lexicon.linkKey, value: value)])
                } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
                    // Left by an earlier try that stopped before the mount kept its key.
                    try await share.apply([.update(collection: Lexicon.link, rkey: Lexicon.linkKey, value: value)])
                }
                var updated = info
                updated.linkKey = Bytes(key)
                _ = try await home.updateMount(try homeNode(mount), updated)
                linkKey = key
            }
        }
        try await home.client.updateSpace(info.space, policy: .members(publicRead: true))
        _ = try await update(nil)
        return ShareLinkAddress(space: info.space, key: linkKey)
    }

    /// Turns a share's public link off: the space isn't public any more, and its link record goes.
    /// An encrypted share gets a new key for what's written from now on (and members get it).
    /// Those who opened the link keep what they already have.
    public func turnLinkOff(_ mount: Node) async throws {
        let mount = try await current(mount)
        let (info, share) = try await ownShare(mount)
        try await home.client.updateSpace(info.space, policy: .members(publicRead: false))
        if (try? await share.client.listRawSpaceRecords(space: info.space, repo: owner, collection: Lexicon.link))?
            .records.isEmpty == false
        {
            try await share.apply([.delete(collection: Lexicon.link, rkey: Lexicon.linkKey)])
        }
        guard info.linkKey != nil || share.keyring != nil else { return }
        var updated = info
        updated.linkKey = nil
        let node = try await home.updateMount(try homeNode(mount), updated)
        if share.keyring != nil {
            try await rotateAndRewrap(node)
        } else {
            _ = try await update(nil)
        }
    }

    /// The link of a share of this account's, if it's on.
    public func link(of mount: Node) async throws -> ShareLinkAddress? {
        let mount = try await current(mount)
        guard let info = mount.record.mount, info.owner == owner else { return nil }
        guard case .members(true, _) = try await home.client.getSpacePolicy(info.space) else { return nil }
        return ShareLinkAddress(space: info.space, key: info.linkKey?.data)
    }

    /// A mount of this account's own share, and the share's drive.
    func ownShare(_ mount: Node) async throws -> (MountInfo, Drive) {
        let mount = try await current(mount)
        guard mount.isMount, let info = mount.record.mount else { throw SharingError.notShared(mount.name) }
        guard info.owner == owner else { throw SharingError.notYours(mount.name) }
        return (info, try await drive(forShare: mount))
    }

    /// A mount as the drive has it now: what a caller holds may be from before a change (a new
    /// key, a link turned on), and acting on that could lose a key.
    func current(_ mount: Node) async throws -> Node {
        let snapshot = try await update(latestSnapshot)
        guard let node = snapshot.tree.nodes[mount.id] else { throw ATDriveError.notFound(mount.name) }
        return node
    }

    // MARK: The recipient's side

    /// Opens a link to look at what's shared: its owner, name and mode, and its drive to read.
    /// Works signed out for a public link (`access` with no account).
    /// `verifiedOwnerKey`: the owner's sharing key, if `me` verified it: a member record from
    /// any other key is refused.
    public static func open(
        _ link: ShareLinkAddress, access: SpaceAccess, sharingKeys: SharingKeyPair? = nil, me: String? = nil,
        verifiedOwnerKey: Data? = nil
    ) async throws -> OpenedShare {
        guard link.isDrive else { throw LinkError.notADrive(link.space) }
        let owner = XRPCClient.spaceParts(link.space)!.authority
        let client = try await access.credentials(for: link.space).client
        let probe = Drive(client: client, owner: owner, space: link.space)
        guard let settings = try await probe.settingsRecord() else { throw SpaceAccessProblem.notShared }
        let encrypted = settings.value.flatMap(SealedRecord.init) != nil
        if !encrypted, link.key != nil { throw SharingError.downgraded }
        var keyring: Keyring?
        if encrypted {
            if let key = link.key {
                keyring = try await ShareLink.keyring(space: link.space, owner: owner, linkKey: key, client: client)
            } else if let sharingKeys, let me {
                keyring = try await MemberKeys.keyring(
                    space: link.space, owner: owner, me: me, keys: sharingKeys, client: client,
                    resolver: access.resolver, verifiedOwnerKey: verifiedOwnerKey)
            } else {
                throw SharingError.linkKeyMissing
            }
        }
        let drive = Drive(
            client: client, owner: owner, space: link.space, mode: encrypted ? .encrypted : .plain, keyring: keyring)
        let opened = try await drive.settings()
        return OpenedShare(
            link: link, owner: owner, name: opened?.name ?? "Shared with me", mode: encrypted ? .encrypted : .plain,
            isFile: opened?.file ?? false, drive: drive)
    }

    /// Adds a share from a link to this drive: a mount at the top level, under the share's name
    /// (renamed if the name is taken). Already added: that mount. Returns the mount.
    @discardableResult
    public func add(_ link: ShareLinkAddress) async throws -> Node {
        // Your own share is in your drive already, as yours: refused before anything else.
        guard !isOwn(link) else { throw LinkError.yourOwn }
        var snapshot = try await update(nil)
        if let existing = snapshot.tree.nodes.values.first(where: { $0.isMount && $0.record.mount?.space == link.space }
        ) {
            return existing
        }
        guard let access else { throw MountUnavailable() }
        let sharingKeys = snapshot.settings?.sharingKeyPair(encrypted: home.mode == .encrypted)
        let verified = try? await verifiedKeys()[XRPCClient.spaceParts(link.space)?.authority ?? ""]
        let opened = try await Self.open(
            link, access: access, sharingKeys: sharingKeys, me: owner, verifiedOwnerKey: verified)
        guard opened.owner != owner else { throw LinkError.yourOwn }
        let taken = Set(snapshot.tree.children(of: nil).map(\.name))
        var name = opened.name
        var counter = 2
        while taken.contains(name) {
            name = "\(opened.name) (\(counter))"
            counter += 1
        }
        let info = MountInfo(
            space: link.space, linkKey: opened.mode == .encrypted ? link.key : nil,
            encrypted: opened.mode == .encrypted)
        let mount = try await home.createMount(info, named: name, in: nil)
        snapshot = try await update(snapshot)
        return snapshot.tree.nodes[mount.id] ?? mount
    }

    /// Whether a link is to one of this account's own shares.
    public func isOwn(_ link: ShareLinkAddress) -> Bool {
        XRPCClient.spaceParts(link.space)?.authority == owner
    }

    /// Where the share a link is to is in this drive, if it's there.
    public func path(of link: ShareLinkAddress) async throws -> DrivePath? {
        let snapshot = try await update(latestSnapshot)
        let mount = snapshot.tree.nodes.values.first { $0.isMount && $0.record.mount?.space == link.space }
        guard let mount else { return nil }
        return snapshot.tree.path(of: mount)
    }

    /// Mounts of other people's shares in this drive.
    public func sharedWithMe(in snapshot: JoinedSnapshot) -> [(mount: Node, state: MountState)] {
        snapshot.mounts.filter(\.value.readOnly).compactMap { id, state in
            snapshot.home.tree.nodes[id].map { ($0, state) }
        }.sorted { $0.mount.name < $1.mount.name }
    }
}

public enum LinkError: Error, Equatable, CustomStringConvertible {
    /// A link to another app's space: the Spaces folder (#28) shows those (`spaces.include`).
    case notADrive(String)
    /// A link to one of this account's own shares.
    case yourOwn

    public var description: String {
        switch self {
        case .notADrive(let space): "\(space) isn't an ATDrive share: it's another app's data"
        case .yourOwn: "that's your own share: it's already in your drive, as yours (links are for other people)"
        }
    }
}

extension SpaceAccessProblem {}

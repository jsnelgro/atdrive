import Crypto
import Foundation

// Sharing (PLAN.md, "Sharing"): a shared file or folder is a space of its own, of the drive's
// type, under the `memberspace` policy, mounted in its owner's drive where it was. Members, and
// anyone with its link when that's on, mount the same space in their own drives, read-only.

extension Drive {
    /// Makes a new space for a share (or any drive of the owner's other than the home one): the
    /// drive's type, `policy`, and settings in the given mode. An encrypted one gets a new keyring
    /// (its own first key, so its own chunk IDs and chunker seed). Returns it, ready to write.
    static func createSpace(
        client: XRPCClient, owner: String, key: String, encrypted: Bool, policy: SpacePolicy, name: String? = nil,
        file: Bool = false, transfers: TransferOptions = .standard, device: String = DeviceName.current,
        tids: TIDSource = .system
    ) async throws -> Drive {
        let space = try await client.createSpace(type: Lexicon.driveSpace, key: key, policy: policy)
        let keyring = encrypted ? Keyring(DriveKey()) : nil
        let drive = Drive(
            client: client, owner: owner, space: space, transfers: transfers, device: device, tids: tids,
            mode: encrypted ? .encrypted : .plain, keyring: keyring)
        try await drive.writeSettingsIfMissing(
            DriveSettings(driveID: DriveSettings.newDriveID(), name: name, file: file))
        return drive
    }

    /// Writes the settings record, unless there is one (an interrupted share, run again).
    func writeSettingsIfMissing(_ settings: DriveSettings) async throws {
        guard try await settingsRecord() == nil else { return }
        do {
            try await apply([
                .create(
                    collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: keyring))
            ])
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {}
    }

    /// Gives a share (this drive) a new name, for those who open it (`DriveSettings.name`).
    func rename(to name: String) async throws {
        try await retryingSettingsRaces {
            guard let record = try await settingsRecord(),
                var settings = settings(stored: record.value, keyring: keyring)
            else { throw DriveAccessError.damaged("settings") }
            guard settings.name != name else { return }
            settings.name = name
            settings.generation += 1
            try await applyChangingSettings(
                [
                    .update(
                        collection: Lexicon.settings, rkey: Lexicon.settingsKey,
                        value: try stored(settings, with: keyring))
                ], generation: settings.generation, read: record)
        }
    }

    /// Writes a mount node: `info`'s space appears as `name` in `parent`.
    @discardableResult
    func createMount(_ info: MountInfo, named name: String, in parent: String?, id: String? = nil) async throws -> Node
    {
        try DrivePath.validate(name: name)
        var record = NodeRecord(name: name, parent: parent, kind: .mount)
        record.mount = info
        return try await commit(change(.create, node: id ?? tids.next(), record: record, .created, prev: nil))!
    }

    /// Changes what a mount holds (a new keyring, say), keeping its place and name.
    @discardableResult
    func updateMount(_ node: Node, _ info: MountInfo) async throws -> Node {
        var record = node.record
        record.mount = info
        return try await commit(change(.update, node: node.id, record: record, .edited, prev: node.record.version))!
    }
}

/// A random space key for a share: 128 bits in base32 (26 characters). A plain share's public link
/// has only its address to protect it, so the address mustn't be guessable.
public func newShareKey() -> String {
    Base32.encode(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
}

/// A share of this account's, as `atdrive shares` shows it.
public struct OwnShare: Sendable, Equatable {
    /// The mount, in the joined tree.
    public var mount: Node
    public var path: DrivePath
    public var space: String
    public var mode: DriveMode?
    public var policy: SpacePolicy?
    public var members: [SpaceMember]
    public var hasLink: Bool { if case .members(true, _)? = policy { true } else { false } }
}

extension JoinedDrive {
    /// The name a mount has while its share is being made: its folder still shows under its own.
    static func sharingName(_ name: String) -> String { "\(name) (sharing…)" }

    /// Moves a file or folder into a space of its own, so it can be shared, and mounts that space
    /// where it was (PLAN.md, "Sharing a folder"). Nothing is shared with anyone yet: no members,
    /// no link. Returns the mount.
    ///
    /// The share takes the drive's mode; `plain` makes a plain one from an encrypted drive
    /// (its files are decrypted and uploaded again). A plain drive makes plain shares only.
    ///
    /// An interrupted share finishes when this runs again: the mount comes first (holding an
    /// encrypted share's keyring, sealed in the drive), named `name (sharing…)`, and nodes keep
    /// their record keys, so what's been copied is known. The folder may show twice meanwhile; it
    /// never disappears.
    @discardableResult
    public func share(_ node: Node, plain: Bool = false) async throws -> Node {
        var snapshot = try await update(nil)
        let path = snapshot.tree.path(of: node)
        guard NodeID.split(node.id).mount == nil else { throw SharingError.nested(path.description) }
        guard !node.isMount else { throw SharingError.alreadyShared(path.description) }
        guard home.mode != nil else { throw DriveAccessError.notOpened }
        let encrypted = home.mode == .encrypted && !plain
        if snapshot.tree.descendants(of: node.id).contains(where: \.isMount) {
            throw SharingError.nested(path.description)
        }
        let parent = snapshot.tree.parent(of: node.id)

        // A share of this one already under way: its mount, by name.
        let pending = snapshot.tree.children(of: parent).first {
            $0.isMount && $0.name == Self.sharingName(node.name) && $0.record.mount?.owner == owner
        }
        var mount: Node
        if let pending {
            mount = pending
        } else {
            let space = try await Drive.createSpace(
                client: home.client, owner: owner, key: newShareKey(), encrypted: encrypted,
                policy: .members(publicRead: false), name: node.name, file: !node.isFolder, transfers: home.transfers,
                device: home.device,
                tids: home.tids)
            mount = try await home.createMount(
                MountInfo(space: space.space, keyring: space.keyring), named: Self.sharingName(node.name), in: parent)
            snapshot = try await update(snapshot)
        }
        guard let target = drive(ofMount: mount.id), let shareTree = snapshot.mounts[mount.id]?.snapshot?.tree else {
            throw ATDriveError.mountUnavailable(
                path: path.description, why: snapshot.mounts[mount.id]?.problem?.description ?? "it can't be read")
        }

        // Copy what isn't there yet, keeping record keys; then the originals go, as `shared`. A
        // folder's space holds what's in it (the mount is the folder); a file's holds the file.
        for item in node.isFolder ? snapshot.tree.children(of: node.id) : [node] {
            try await copyForSharing(item, in: snapshot.tree, to: target, parent: nil, existing: shareTree)
        }
        let inside = node.isFolder ? snapshot.tree.descendants(of: node.id) : []
        try await home.delete(inside + [node], recordedAs: .shared)
        snapshot = try await update(snapshot)
        guard let written = snapshot.tree.nodes[mount.id] else { throw ATDriveError.notFound(path.description) }
        _ = try await move(written, to: parent, as: node.name)
        return try await current(written)
    }

    /// Copies a node of the home drive (and what's in it) into a share's space, keeping record
    /// keys, skipping what's there already (an interrupted share, run again).
    private func copyForSharing(
        _ node: Node, in tree: DriveTree, to target: Drive, parent: String?, existing: DriveTree
    )
        async throws
    {
        let done =
            existing.nodes[node.id]
            ?? existing.children(of: parent).first { $0.name == node.name && $0.isFolder == node.isFolder }
        let written: Node
        if let done {
            written = done
        } else if node.isFolder || home.mode == target.mode {
            do {
                written = try await target.writeCopy(of: node.record, id: node.id, in: parent, as: node.name)
            } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
                return
            }
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "atdrive-share-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            try await home.download(node, to: scratch)
            written = try await target.upload(scratch, as: node.name, in: parent, modified: node.record.modifiedDate)
        }
        guard node.isFolder else { return }
        for child in tree.children(of: node.id) {
            try await copyForSharing(child, in: tree, to: target, parent: written.id, existing: existing)
        }
    }

    /// Stops sharing a share of this account's. Nobody else can read it from that moment (the
    /// space goes back to `personalspace`, its member and link records deleted); then it moves
    /// back into the drive, where it is, an ordinary file or folder again, and its space is
    /// deleted (so those who had it see it gone). Run again, it finishes an interrupted one.
    public func unshare(_ mount: Node) async throws {
        let mount = try await current(mount)
        guard mount.isMount, let info = mount.record.mount else { throw SharingError.notShared(mount.name) }
        guard info.owner == owner else { throw SharingError.notYours(mount.name) }
        try await stopSharing(info)
        let snapshot = try await update(latestSnapshot)
        guard let share = drive(ofMount: mount.id), let tree = snapshot.mounts[mount.id]?.snapshot?.tree else {
            throw ATDriveError.mountUnavailable(
                path: mount.name, why: snapshot.mounts[mount.id]?.problem?.description ?? "it can't be read")
        }
        try await unmount(
            mount, share: share, shareTree: tree, file: snapshot.sharedFile(of: mount.id), joined: snapshot.tree)
    }

    /// Nobody but its owner can read a space of this account's any more: `personalspace` (which
    /// drops members and `publicRead`), its member and link records gone, and its invites taken
    /// back.
    func stopSharing(_ info: MountInfo) async throws {
        // Who has it, for taking their invites back: the member list goes with the policy.
        let members = (try? await home.client.listMembers(info.space)) ?? []
        try await home.client.updateSpace(info.space, policy: .personal)
        await withdrawInvites(members.map(\.did), from: info.space)
        let share = Drive(client: home.client, owner: owner, space: info.space)
        let records = try await shareRecords(share)
        if !records.isEmpty {
            try await share.apply(records.map { .delete(collection: $0.collection, rkey: $0.rkey) })
        }
    }

    /// The member and link records in a share.
    func shareRecords(_ share: Drive) async throws -> [(collection: String, rkey: String)] {
        var found: [(String, String)] = []
        for collection in [Lexicon.member, Lexicon.link] {
            let page = try await share.client.listRawSpaceRecords(
                space: share.space, repo: share.owner, collection: collection)
            found += page.records.map { (collection, $0.rkey) }
        }
        return found
    }

    /// An encrypted share of this account's gets a new key: what's written from now on is sealed
    /// with it. Stored in the mount (sealed in the drive); members and the link get it from their
    /// records, which `Sharing` rewrites.
    @discardableResult
    func rotateKey(of mount: Node) async throws -> Keyring? {
        let mount = try await current(mount)
        guard let info = mount.record.mount, var keyring = info.spaceKeyring else { return nil }
        _ = keyring.rotate()
        let local = try homeNode(mount)
        _ = try await home.updateMount(local, info.with(keyring))
        opened.update { $0[mount.id] = nil }
        _ = try await update(nil)
        return keyring
    }

    /// A mount as the home drive has it.
    func homeNode(_ node: Node) throws -> Node {
        guard NodeID.split(node.id).mount == nil else { throw SharingError.nested(node.name) }
        guard node.isMount, node.record.kind != .mount else { return node }
        // A share of one file, as the joined tree shows it: the mount as the home drive has it.
        guard let stored = latestSnapshot?.home.tree.nodes[node.id] else { throw ATDriveError.notFound(node.name) }
        return stored
    }

    /// The drive of a share of this account's, opened.
    func drive(forShare mount: Node) async throws -> Drive {
        if let drive = drive(ofMount: mount.id) { return drive }
        _ = try await update(nil)
        guard let drive = drive(ofMount: mount.id) else {
            throw ATDriveError.mountUnavailable(path: mount.name, why: "it can't be read")
        }
        return drive
    }

    /// This account's shares, with their members and whether they have a link.
    public func ownShares(in snapshot: JoinedSnapshot) async throws -> [OwnShare] {
        var shares: [OwnShare] = []
        for (id, state) in snapshot.mounts.sorted(by: { $0.key < $1.key }) where !state.readOnly {
            guard let mount = snapshot.tree.nodes[id] else { continue }
            let policy = try? await home.client.getSpacePolicy(state.space)
            var members: [SpaceMember] = []
            if case .members? = policy { members = (try? await home.client.listMembers(state.space)) ?? [] }
            shares.append(
                OwnShare(
                    mount: mount, path: snapshot.tree.path(of: mount), space: state.space, mode: state.mode,
                    policy: policy, members: members))
        }
        return shares
    }

    /// Ends all sharing, for switching the drive's encryption (PLAN.md, "Encrypted and plain
    /// shares"): each share of this account's moves back into the drive, where it was, and its
    /// space is deleted (members and link holders are told so); mounts of other people's shares
    /// are removed. Then everything converts with the drive, and no keyring is left behind.
    /// Returns the paths of the shares that ended.
    @discardableResult
    public func endSharing() async throws -> [String] {
        var snapshot = try await update(nil)
        var ended: [String] = []
        for (id, state) in snapshot.mounts.sorted(by: { $0.key < $1.key }) {
            guard let mount = snapshot.tree.nodes[id] else { continue }
            let path = snapshot.tree.path(of: mount).description
            if state.readOnly {
                try await home.delete([try homeNode(mount)])
            } else {
                guard state.problem == nil, let share = drive(ofMount: id), let tree = state.snapshot?.tree else {
                    throw ATDriveError.mountUnavailable(
                        path: path, why: state.problem?.description ?? "it can't be read")
                }
                try await unmount(
                    mount, share: share, shareTree: tree, file: snapshot.sharedFile(of: id), joined: snapshot.tree)
            }
            ended.append(path)
            snapshot = try await update(snapshot)
        }
        return ended
    }

    /// Moves a share's contents back into the home drive, in the mount's place, and deletes its
    /// space. `file`: the file a share of one file holds. What an interrupted run left half-copied
    /// is deleted first.
    private func unmount(_ mount: Node, share: Drive, shareTree: DriveTree, file: Node?, joined: DriveTree)
        async throws
    {
        let parent = joined.parent(of: mount.id)
        let leftovers = joined.children(of: parent).filter {
            $0.name == Self.unmountingName(mount.name) && !$0.isMount
        }
        if !leftovers.isEmpty {
            try await home.delete(leftovers.flatMap { joined.descendants(of: $0.id) + [$0] })
        }
        let top = shareTree.children(of: nil)
        // Shares made before `DriveSettings.file`: one file of the mount's name.
        let file =
            file ?? top.first.flatMap { top.count == 1 && !$0.isFolder && $0.name == mount.name ? $0 : nil }
        if let file {
            // A shared file: it comes back as the file, copied before the mount goes.
            let global = Node(id: NodeID.join(mount.id, file.id), cid: file.cid, record: file.record)
            let copied = try await copy(
                global, in: joined, from: share, to: home, parent: parent, as: Self.unmountingName(mount.name))
            try await home.delete([try homeNode(mount)])
            try await home.client.deleteSpace(share.space)
            _ = try await home.move(copied, to: parent, as: mount.name)
            return
        }
        let folder = try await home.createFolder(named: Self.unmountingName(mount.name), in: parent)
        for child in shareTree.children(of: nil) {
            let global = Node(id: NodeID.join(mount.id, child.id), cid: child.cid, record: child.record)
            _ = try await copy(global, in: joined, from: share, to: home, parent: folder.id, as: child.name)
        }
        try await home.delete([try homeNode(mount)])
        try await home.client.deleteSpace(share.space)
        _ = try await home.move(folder, to: parent, as: mount.name)
    }

    static func unmountingName(_ name: String) -> String { "\(name) (unsharing…)" }
}

import Crypto
import Foundation

// Sharing with specific people (PLAN.md, "Keys for encrypted shares"). Members are on the
// space's member list (`putMembers`), so the PDS lets them read it. An encrypted share also gives
// each one its keyring, wrapped for the sharing key they published, in a member record.

extension Drive {
    /// Changes the home drive's settings, keeping them in the drive's form (sealed on an
    /// encrypted drive), and remembers the new record so it isn't taken for someone else's change.
    /// If another device changes them at the same moment, `change` is made again, to theirs.
    func updateSettings(_ change: (inout DriveSettings) -> Void) async throws -> DriveSettings {
        try await retryingSettingsRaces(reopening: true) {
            guard let mode else { throw DriveAccessError.notOpened }
            guard let record = try await settingsRecord(),
                var settings = settings(stored: record.value, keyring: mode == .encrypted ? keyring : nil)
            else { throw DriveAccessError.damaged("settings") }
            if mode == .encrypted, keyring == nil { throw DriveAccessError.locked }
            change(&settings)
            settings.generation += 1
            let cids = try await applyChangingSettings(
                [
                    .update(
                        collection: Lexicon.settings, rkey: Lexicon.settingsKey,
                        value: try stored(settings, with: mode == .encrypted ? keyring : nil))
                ], generation: settings.generation, read: record)
            if mode == .encrypted, let keyring, let me = identity {
                accept(
                    keyring, as: me, settings: settings, deviceRecord: keys.value.deviceRecord, settingsRecord: cids[0])
            } else if mode == .plain {
                becomePlain(settings, settingsRecord: cids[0])
            }
            return settings
        }
    }
}

/// A member of a share of this account's, as `atdrive shares` shows them.
public struct ShareMember: Sendable, Equatable {
    public var did: String
    /// For an encrypted share: the sharing key their keyring is wrapped for.
    public var fingerprint: String?
    /// Whether their own drive is encrypted (their sharing key is kept encrypted). If not, whoever
    /// runs their PDS can read what's shared with them.
    public var protected: Bool?
    /// Their sharing key changed since their keyring was wrapped: they get none for what's new
    /// until they're added again.
    public var keyChanged: Bool
    /// Their published sharing key is the one you verified with a code (`atdrive verify`).
    public var verified: Bool = false
}

/// Something to know before someone is added to an encrypted share.
public enum MemberWarning: Sendable, Equatable, CustomStringConvertible {
    /// Their drive isn't encrypted: their PDS could read the share.
    case unprotected(String)
    /// Their sharing key isn't the one their keyring was wrapped for last time, or the one you
    /// verified.
    case keyChanged(String, from: String, to: String)

    public var description: String {
        switch self {
        case .unprotected(let who):
            "\(who)'s drive isn't encrypted, so whoever runs their PDS could read this share"
        case .keyChanged(let who, let from, let to):
            "\(who)'s sharing key changed (\(from) → \(to)): it may be a new device setup, or their PDS "
                + "putting in a key of its own; compare verification codes (`atdrive verify`) if unsure"
        }
    }
}

extension JoinedDrive {
    // MARK: This account's sharing key

    /// This account's sharing key: made the first time (or after encryption was switched, which
    /// drops it), kept in the home drive's settings, and published. Published again if what's
    /// published isn't it.
    @discardableResult
    public func ensureSharingKey() async throws -> SharingKeyPair {
        let encrypted = home.mode == .encrypted
        var settings = try await home.settings()
        if settings?.sharingKey == nil {
            let key = Curve25519.KeyAgreement.PrivateKey()
            // Another device may make one meanwhile: theirs is kept.
            settings = try await home.updateSettings {
                if $0.sharingKey == nil { $0.sharingKey = Bytes(key.rawRepresentation) }
            }
        }
        guard let pair = settings?.sharingKeyPair(encrypted: encrypted) else {
            throw DriveAccessError.damaged("settings")
        }
        let published = try await home.client.getPublicRecord(
            repo: owner, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey
        ).flatMap { try? $0.decode(as: SharingKeyRecord.self) }
        if published?.publicKey.data != pair.publicKey.rawRepresentation || published?.protected != encrypted {
            try await home.client.putPublicRecord(
                repo: owner, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey,
                record: try JSONValue(encoding: SharingKeyRecord(publicKey: pair.publicKey, protected: encrypted)))
        }
        return pair
    }

    // MARK: Members

    /// What adding these people to an encrypted share should warn about first: drives that
    /// aren't encrypted, and sharing keys that changed. Throws `noSharingKey` for someone who
    /// has none (they haven't used ATDrive): send them a link instead. Nothing for a plain share.
    public func memberWarnings(_ dids: [String], for mount: Node) async throws -> [MemberWarning] {
        let (info, share) = try await ownShare(mount)
        guard share.keyring != nil, let resolver = access?.resolver else { return [] }
        let existing = try await memberEntries(share)
        let verified = try await verifiedKeys()
        var warnings: [MemberWarning] = []
        for did in dids {
            guard
                let published = try await SharingKeyRecord.fetch(
                    did, resolver: resolver, transport: home.client.transport)
            else { throw SharingError.noSharingKey(did) }
            if !published.protected { warnings.append(.unprotected(did)) }
            if let known = verified[did].map(Bytes.init) ?? existing[did]?.publicKey, known != published.publicKey {
                warnings.append(
                    .keyChanged(
                        did, from: SharingKeyRecord.fingerprint(of: known.data), to: published.fingerprint))
            }
        }
        _ = info
        return warnings
    }

    /// Adds people (by DID), read-only. For an encrypted share, each gets the keyring wrapped for
    /// the sharing key they published (check `memberWarnings` first). Already members: their
    /// keyring is wrapped again, for the key they publish now. A key that changed since it was
    /// verified or last wrapped for is refused (`keyChanged`) unless `allowingChangedKeys`: the
    /// owner checked it.
    ///
    /// Each one is then invited (`invite`): it waits for them among their pending shares. Returns
    /// who couldn't be invited; they're members all the same, and can open it from its link.
    @discardableResult
    public func addMembers(_ dids: [String], to mount: Node, allowingChangedKeys: Bool = false) async throws
        -> [InviteFailure]
    {
        let (info, share) = try await ownShare(mount)
        if case .members = try await home.client.getSpacePolicy(info.space) {
        } else {
            // Unshared since (`personalspace`): members again, link off.
            try await home.client.updateSpace(info.space, policy: .members(publicRead: false))
        }
        if !allowingChangedKeys {
            for warning in try await memberWarnings(dids, for: mount) {
                if case .keyChanged(let did, _, _) = warning { throw SharingError.keyChanged(did) }
            }
        }
        try await home.client.putMembers(info.space, dids.map { SpaceMember(did: $0) })
        guard let keyring = share.keyring else { return await invite(dids, to: info.space) }
        guard let resolver = access?.resolver else { throw MountUnavailable() }
        let mine = try await ensureSharingKey()
        var writes: [SpaceWrite] = []
        let existing = try await memberEntries(share)
        for did in dids {
            guard
                let published = try await SharingKeyRecord.fetch(
                    did, resolver: resolver, transport: home.client.transport),
                let key = published.key
            else { throw SharingError.noSharingKey(did) }
            let value = try MemberKeys.record(keyring: keyring, for: did, key: key, from: mine, space: info.space)
            writes.append(
                existing[did] == nil
                    ? .create(collection: Lexicon.member, rkey: did, value: value)
                    : .update(collection: Lexicon.member, rkey: did, value: value))
        }
        for batch in share.transactions(writes) { try await share.apply(batch) }
        return await invite(dids, to: info.space)
    }

    /// Removes people. Their member records go, and an encrypted share gets a new key for what's
    /// written from now on, wrapped for those who stay. What they already have stays theirs.
    public func removeMembers(_ dids: [String], from mount: Node) async throws {
        let (info, share) = try await ownShare(mount)
        try await home.client.removeMembers(info.space, dids: dids)
        await withdrawInvites(dids, from: info.space)
        let existing = try await memberEntries(share)
        let doomed = dids.filter { existing[$0] != nil }
        if !doomed.isEmpty {
            try await share.apply(doomed.map { .delete(collection: Lexicon.member, rkey: $0) })
        }
        if share.keyring != nil { try await rotateAndRewrap(mount) }
    }

    /// A share's members, with what's known of their keys.
    public func members(of mount: Node) async throws -> [ShareMember] {
        let (info, share) = try await ownShare(mount)
        let listed = try await home.client.listMembers(info.space)
        guard share.keyring != nil else {
            return listed.map { ShareMember(did: $0.did, fingerprint: nil, protected: nil, keyChanged: false) }
        }
        let entries = try await memberEntries(share)
        let verified = try await verifiedKeys()
        var members: [ShareMember] = []
        for member in listed {
            var published: SharingKeyRecord?
            if let resolver = access?.resolver {
                published = try? await SharingKeyRecord.fetch(
                    member.did, resolver: resolver, transport: home.client.transport)
            }
            let wrappedFor = entries[member.did]?.publicKey
            members.append(
                ShareMember(
                    did: member.did, fingerprint: (wrappedFor?.data).map(SharingKeyRecord.fingerprint(of:)),
                    protected: published?.protected,
                    keyChanged: published.map { $0.publicKey != wrappedFor } ?? false,
                    verified: published.map { verified[member.did] == $0.publicKey.data } ?? false))
        }
        return members
    }

    /// The member records of a share, opened: who each keyring was wrapped for. A record that
    /// doesn't open (made by someone else, or changed) isn't there.
    func memberEntries(_ share: Drive) async throws -> [String: MemberEntry] {
        guard let keyring = share.keyring else { return [:] }
        let page = try await share.client.listRawSpaceRecords(
            space: share.space, repo: share.owner, collection: Lexicon.member)
        var entries: [String: MemberEntry] = [:]
        for record in page.records {
            guard let value = record.value, let member = try? value.decode(as: MemberRecord.self),
                let entry = try? keyring.open(
                    member.membership, as: MemberEntry.self, space: share.space, collection: Lexicon.member,
                    rkey: record.rkey),
                entry.did == record.rkey
            else { continue }
            entries[record.rkey] = entry
        }
        return entries
    }

    /// Gives an encrypted share of this account's a new key, for what's written from now on: in
    /// the mount, then wrapped again for each member (for the key it was wrapped for before) and
    /// sealed again for the link, if it's on.
    func rotateAndRewrap(_ mount: Node) async throws {
        let share = try await drive(forShare: mount)
        let entries = try await memberEntries(share)
        guard let keyring = try await rotateKey(of: mount), let info = latestMount(mount.id)?.record.mount else {
            return
        }
        let rotated = try await drive(forShare: latestMount(mount.id) ?? mount)
        let mine = try await ensureSharingKey()
        var writes: [SpaceWrite] = []
        for (did, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: entry.publicKey.data) else {
                continue
            }
            writes.append(
                .update(
                    collection: Lexicon.member, rkey: did,
                    value: try MemberKeys.record(keyring: keyring, for: did, key: key, from: mine, space: info.space)))
        }
        if let linkKey = info.linkKey {
            writes.append(
                .update(
                    collection: Lexicon.link, rkey: Lexicon.linkKey,
                    value: try ShareLink.record(for: keyring, linkKey: linkKey.data, space: info.space)))
        }
        for batch in rotated.transactions(writes) { try await rotated.apply(batch) }
    }

    /// A mount as the latest snapshot has it.
    func latestMount(_ id: String) -> Node? { latestSnapshot?.tree.nodes[id] }
}

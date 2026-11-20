import Crypto
import Foundation

// Pending shares (#68). The protocol tells nobody when they're added to a space (0016: `putMembers`
// notifies no one, and `listSpaces` leaves out spaces you're only a member of, #56), so ATDrive
// delivers invites itself, in spaces:
//
// - Each account has an inbox, `at://<did>/space/app.atdrive.inbox/self`: a `memberspace` with no
//   members, so only its owner reads it, and `publicWrite`, so the space's host tracks anyone's
//   writes to it (`listWriters`).
// - Sharing with someone writes an invite (`app.atdrive.invite`, keyed by the share's space key)
//   into the sharer's own repo in their inbox. Their PDS hears of it, as of any write to a space
//   it's the authority of.
// - The recipient lists the inbox's writers, reads each one's invites, and shows the shares they
//   name that aren't in their drive yet (and weren't declined): pending shares. Accepting one
//   mounts it, as opening its link does; declining one remembers that in the home drive.
//
// An invite gives no access: being on the share's member list does, and a pending share is opened
// (as a member) to show its name. An invite names only the share, so an encrypted share's name
// stays sealed. Only a sender's own shares count: an invite to anyone else's is ignored.

/// An invite, as its sender writes it: `app.atdrive.invite` in their repo in the recipient's inbox.
public struct InviteRecord: Codable, Sendable, Equatable {
    /// The share's space: the sender's.
    public var space: String
    public var createdAt: String

    public init(space: String, createdAt: Date = Date()) {
        self.space = space
        self.createdAt = Timestamp.format(createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case space, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        space = try container.decode(String.self, forKey: .space)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Lexicon.invite, forKey: .type)
        try container.encode(space, forKey: .space)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// A share this account declined: `app.atdrive.declined` in the home drive (sealed on an encrypted
/// drive), keyed by `key(for:)`.
public struct DeclinedShare: Codable, Sendable, Equatable {
    public var space: String
    public var declinedAt: String

    public init(space: String, declinedAt: Date = Date()) {
        self.space = space
        self.declinedAt = Timestamp.format(declinedAt)
    }

    /// The record key for a share: a space's address holds slashes, which a record key can't.
    public static func key(for space: String) -> String { SHA256.hash(data: Data(space.utf8)).prefix(16).hexString }
}

/// A share someone sent this account, waiting for it to accept or decline it.
public struct PendingShare: Sendable, Equatable, Identifiable {
    /// The share's space.
    public var space: String
    /// Who shared it.
    public var owner: String
    /// When they shared it (as they say).
    public var sentAt: Date?
    /// What it is, once opened: `nil` if it can't be opened now (`problem` says why).
    public var name: String?
    public var isFile: Bool
    public var mode: DriveMode?
    /// Why it can't be opened now. It stays pending: it may open later.
    public var problem: String?

    public var id: String { space }
    /// Its link (without a key: a member needs none).
    public var link: ShareLinkAddress { ShareLinkAddress(space: space) }
}

/// Why an invite couldn't be sent: the share is still theirs to open, from its link.
public struct InviteFailure: Sendable, Equatable, CustomStringConvertible {
    public var did: String
    public var reason: String

    public var description: String { "couldn't tell \(did) about it: \(reason)" }
}

extension XRPCClient {
    /// An account's inbox.
    public static func inbox(of did: String) -> String {
        spaceURI(authority: did, type: Lexicon.inboxSpace, key: Lexicon.inboxKey)
    }
}

extension JoinedDrive {
    /// The inbox's policy: only its owner reads it, and anyone's invites in it are tracked.
    static let inboxPolicy = SpacePolicy.members(publicRead: false, publicWrite: true)

    /// This account's inbox.
    public var inbox: String { XRPCClient.inbox(of: owner) }

    // MARK: Receiving

    /// Makes this account's inbox, so people can say they've shared something with it. Already
    /// there: its policy is checked (and put right).
    public func ensureInbox() async throws {
        do {
            try await home.client.createSpace(type: Lexicon.inboxSpace, key: Lexicon.inboxKey, policy: Self.inboxPolicy)
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {
            if try await home.client.getSpacePolicy(inbox) != Self.inboxPolicy {
                try await home.client.updateSpace(inbox, policy: Self.inboxPolicy)
            }
        }
    }

    /// The shares waiting for this account: those people invited it to that aren't in its drive
    /// (wherever they are) and weren't declined, newest first. Each is opened, as a member, for
    /// its name: one that says this account isn't a member (any more) isn't pending; one that
    /// can't be opened for another reason is, with why. No inbox yet: one is made, and nothing
    /// is pending.
    public func pendingShares() async throws -> [PendingShare] {
        guard let access else { throw MountUnavailable() }
        let credentials = try await access.credentials(for: inbox)
        let writers: [SpaceWriter]
        do {
            writers = try await credentials.client.listWriters(space: inbox)
        } catch let error where SpaceAccessProblem(error) == .notShared {
            try await ensureInbox()
            return []
        }
        let snapshot = try await update(latestSnapshot)
        var skipped = Set(snapshot.home.tree.nodes.values.compactMap { $0.record.mount?.space })
        skipped.formUnion(try await declinedShares())

        var invites: [(owner: String, record: InviteRecord)] = []
        for writer in writers where writer.did != owner {
            guard let pds = try? await access.resolver.resolve(writer.did).pds else { continue }
            let client = XRPCClient(service: pds, credentials: credentials, transport: access.transport)
            guard
                let page = try? await client.listRawSpaceRecords(
                    space: inbox, repo: writer.did, collection: Lexicon.invite)
            else { continue }
            for record in page.records {
                guard let invite = try? record.value?.decode(as: InviteRecord.self),
                    let parts = XRPCClient.spaceParts(invite.space),
                    parts.authority == writer.did, parts.type == Lexicon.driveSpace,
                    !skipped.contains(invite.space)
                else { continue }
                skipped.insert(invite.space)
                invites.append((writer.did, invite))
            }
        }

        let sharingKeys = snapshot.settings?.sharingKeyPair(encrypted: home.mode == .encrypted)
        let verified = (try? await verifiedKeys()) ?? [:]
        var pending: [PendingShare] = []
        for (sender, invite) in invites {
            var share = PendingShare(
                space: invite.space, owner: sender, sentAt: Timestamp.parse(invite.createdAt), isFile: false)
            do {
                let opened = try await Self.open(
                    share.link, access: access, sharingKeys: sharingKeys, me: owner,
                    verifiedOwnerKey: verified[sender])
                share.name = opened.name
                share.isFile = opened.isFile
                share.mode = opened.mode
            } catch {
                if let problem = SpaceAccessProblem(error), problem == .notShared || problem == .deleted {
                    continue  // taken back, or gone: an invite left behind
                }
                share.problem = String(describing: error)
            }
            pending.append(share)
        }
        return pending.sorted {
            ($0.sentAt ?? .distantPast, $1.space) > ($1.sentAt ?? .distantPast, $0.space)
        }
    }

    /// Puts a pending share in the drive, at the top, as opening its link does. Returns the mount.
    @discardableResult
    public func accept(_ share: PendingShare) async throws -> Node {
        try await add(share.link)
    }

    /// Declines a pending share: it isn't pending any more, on any of this account's devices. Its
    /// owner isn't told, and it can still be added from its link.
    public func decline(_ share: PendingShare) async throws {
        let rkey = DeclinedShare.key(for: share.space)
        let value = try home.stored(DeclinedShare(space: share.space), collection: Lexicon.declined, rkey: rkey)
        do {
            try await home.apply([.create(collection: Lexicon.declined, rkey: rkey, value: value)])
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {}
    }

    /// The shares this account declined.
    func declinedShares() async throws -> Set<String> {
        var declined: Set<String> = []
        var cursor: String?
        repeat {
            let page = try await home.client.listRawSpaceRecords(
                space: home.space, repo: owner, collection: Lexicon.declined, cursor: cursor)
            for record in page.records {
                if let share = home.read(
                    record.value, as: DeclinedShare.self, collection: Lexicon.declined, rkey: record.rkey)
                {
                    declined.insert(share.space)
                }
            }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return declined
    }

    // MARK: Sending

    /// Tells people a share of this account's is waiting for them: an invite in each one's inbox.
    /// Sent again, it's written again (which tells their PDS again). Returns who couldn't be told:
    /// they're still members, and can open it from its link.
    func invite(_ dids: [String], to space: String) async -> [InviteFailure] {
        guard let key = XRPCClient.spaceParts(space)?.key else { return [] }
        var failures: [InviteFailure] = []
        for did in dids {
            do {
                try await home.client.putSpaceRecord(
                    space: XRPCClient.inbox(of: did), repo: owner, collection: Lexicon.invite, rkey: key,
                    record: InviteRecord(space: space))
            } catch {
                failures.append(InviteFailure(did: did, reason: Self.describeInviteFailure(error)))
            }
        }
        return failures
    }

    /// Takes invites back (people taken off a share, or it isn't shared any more). Best effort: an
    /// invite left behind names a share they can't open, which isn't shown.
    func withdrawInvites(_ dids: [String], from space: String) async {
        guard let key = XRPCClient.spaceParts(space)?.key else { return }
        for did in dids {
            _ = try? await home.client.applySpaceWrites(
                space: XRPCClient.inbox(of: did), repo: owner,
                writes: [.delete(collection: Lexicon.invite, rkey: key)])
        }
    }

    static func describeInviteFailure(_ error: Error) -> String {
        if let error = error as? XRPCError, SpaceData.isScopeRefusal(error) {
            return "sign in again (`atdrive login`) to let ATDrive send invites"
        }
        return String(describing: error)
    }
}

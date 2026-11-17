import Crypto
import Foundation

/// Whether a drive is encrypted. It's a property of the drive, read from how its settings
/// record is stored (`Drive.open`), and it can change (`Drive.enableEncryption`,
/// `Drive.disableEncryption`).
public enum DriveMode: String, Sendable, Equatable, Codable {
    /// Records and file contents are stored as they are: whoever runs the PDS can read them. No
    /// keys, no devices to approve, nothing to lose. The default.
    case plain
    /// Records are sealed and file contents encrypted with keys only the drive's devices hold.
    case encrypted
}

/// What this device knows of the drive's mode and keys (`Drive.keys`).
struct DriveKeys: Sendable {
    /// `nil` until the drive is opened (or created): it can't be written to before.
    var mode: DriveMode?
    /// An encrypted drive's keyring; `nil` while this device doesn't have it.
    var keyring: Keyring?
    /// Keys the drive used to have, published in its settings: they open what's still sealed
    /// with them, and seal nothing.
    var retired: Keyring?
    /// An encrypted drive that's still encrypting what was there before
    /// (`DriveSettings.converting`).
    var converting = false
    var identity: DeviceIdentity?
    /// The CIDs of this device's record and of the settings record when the drive was last
    /// opened (or that was tried): when either changes, `refreshKeys` opens it again.
    var deviceRecord: String?
    var settingsRecord: String?
    /// Why the last try to open the drive again failed, if it did.
    var problem: DriveAccessError?

    /// Whether records that aren't sealed with the drive's current keys are read. Always on a
    /// plain drive; on an encrypted one only while it's converting, since the PDS could have
    /// written them.
    var acceptsUnsealed: Bool { mode != .encrypted || converting }
}

/// A value shared between tasks, behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    @discardableResult
    func update<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }
}

/// Why this device can't open the drive, or a change to its keys and devices can't be made.
public enum DriveAccessError: Error, Equatable, CustomStringConvertible {
    /// The account has no drive. Creating one shows its recovery key, so only `atdrive login`
    /// (or the Mac app's first sign-in) does.
    case noDrive
    /// This device doesn't have the drive's keys: it hasn't asked for them (`pending: false`), or
    /// it's waiting for another device to approve it.
    case notApproved(pending: Bool)
    /// This device's record holds a keyring wrapped by a device it doesn't trust (named as its
    /// record names it). It's ignored: the PDS can wrap a keyring for anyone.
    case untrustedKeyring(sender: String)
    /// This device's record holds a keyring without a key this device has seen before: one made
    /// up, or an old one played back. It's ignored.
    case keyringMissingKeys
    /// Writing needs the drive's keys, and this device hasn't unlocked the drive.
    case locked
    /// The drive hasn't been opened, so it isn't known yet whether it's encrypted.
    case notOpened
    /// The drive's settings say it isn't encrypted any more, but they don't hold the keys this
    /// device had. Its own devices publish them when they turn encryption off; the PDS can't.
    case encryptionRemoved
    /// The drive's settings are older than ones this device has read: an old copy.
    case settingsRolledBack
    /// Turning encryption on, on a drive that's encrypted; or off, on one that isn't.
    case alreadyEncrypted
    case notEncrypted
    /// Creating a drive, when the account has one (another device made it first).
    case driveExists
    /// That recovery key doesn't open the drive's recovery record.
    case wrongRecoveryKey
    /// Removing a device that held the drive's keys means wrapping the new keyring for the
    /// recovery key, and only the recovery key itself can do that.
    case recoveryKeyNeeded
    case cannotRemoveThisDevice
    case noSuchDevice(String)
    /// One of the drive's own records (its settings, or the recovery record) can't be read.
    case damaged(String)

    public var description: String {
        switch self {
        case .noDrive:
            "this account has no drive yet: run `atdrive login` to create one"
        case .notApproved(pending: false):
            "this device doesn't have the drive's keys: run `atdrive login` to ask for them, or "
                + "`atdrive unlock` to use the recovery key"
        case .notApproved(pending: true):
            "this device is waiting to be approved: run `atdrive devices approve` on a device that has the "
                + "drive's keys (or `atdrive login` here to compare codes), or `atdrive unlock` to use the "
                + "recovery key"
        case .untrustedKeyring(let sender):
            "ignored the keys wrapped for this device by \(sender): it isn't a device this one trusts. "
                + "Approve this device again (`atdrive login`), or run `atdrive unlock` with the recovery key"
        case .keyringMissingKeys:
            "ignored the keys wrapped for this device: they lack a key it had before (an old copy, or not "
                + "the drive's). Approve this device again (`atdrive login`), or run `atdrive unlock` with the "
                + "recovery key"
        case .locked:
            "this device doesn't have the drive's keys (run `atdrive login`)"
        case .notOpened:
            "the drive hasn't been opened yet"
        case .encryptionRemoved:
            "the drive's settings say it's no longer encrypted, but they don't prove that one of your "
                + "devices turned encryption off: the server may have changed them. Nothing was written. If "
                + "you did turn it off, run `atdrive login` to accept that"
        case .settingsRolledBack:
            "the server returned an older copy of the drive's settings than this device has seen. Nothing "
                + "was written"
        case .alreadyEncrypted:
            "the drive is already encrypted"
        case .notEncrypted:
            "the drive isn't encrypted, so it has no keys, devices to approve, or recovery key "
                + "(`atdrive encryption on` turns encryption on)"
        case .driveExists:
            "this account already has a drive"
        case .wrongRecoveryKey:
            "that isn't this drive's recovery key"
        case .recoveryKeyNeeded:
            "the drive's new key must be wrapped for the recovery key: enter it, or make a new one"
        case .cannotRemoveThisDevice:
            "this is the device you're using: remove it from another device"
        case .noSuchDevice(let device):
            "no device \(device) in this drive"
        case .damaged(let what):
            "the drive's \(what) can't be read"
        }
    }
}

/// A device record as stored.
public struct DeviceEntry: Sendable, Equatable, Identifiable {
    /// The device's ID: the record key.
    public var id: String
    public var cid: String
    public var record: DeviceRecord
}

/// A device in the drive, as `Drive.devices()` lists it.
public struct DeviceInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Its raw public key: the one a pairing code is computed from, and the keyring wrapped for.
    public var publicKey: Bytes
    /// It holds the drive's keys: its record's `member` opens with the drive's current key.
    /// Without the keys to check that, its record says so, which proves nothing.
    public var approved: Bool
    public var isThisDevice: Bool

    /// The code to compare with this device's (see `PairingCode`).
    public func pairingCode(with identity: DeviceIdentity) throws -> String {
        PairingCode.make(
            for: identity.publicKey, and: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey.data))
    }
}

/// A keyring wrapped for this device while it waited to be approved (`Drive.arrivedKeyring`).
public struct ArrivedKeyring: Sendable, Equatable {
    /// The device that wrapped it, as the roster that keyring opens names it.
    public var sender: RosterEntry
    /// The pairing code over this device's key and the sender's: what the approving device showed.
    public var code: String
    /// The CID of this device's record, holding it.
    public var cid: String
}

/// The drive's key records as stored.
struct KeyRecords {
    var settings: (cid: String, value: JSONValue?)
    var devices: [String: DeviceEntry]
    var recovery: RecoveryRecord?

    /// What a sender's device record calls it, for messages only: the PDS can change it.
    func name(of sender: Bytes) -> String {
        devices.values.first { $0.record.publicKey == sender }.map { "“\($0.record.name)”" } ?? "an unknown device"
    }
}

/// Whether a device takes a keyring wrapped for it.
///
/// Anyone, the PDS included, can wrap a keyring for a device's public key, and HPKE's auth mode
/// says who did. A device that took any keyring would seal new records with whatever key the PDS
/// handed it. So it takes one only:
/// - wrapped by itself (when it created the drive, unlocked it with the recovery key, or rotated
///   the keyring);
/// - for its first keyring, wrapped by the device that approved it, whose pairing code the user
///   compared (`DeviceTrust.approver`);
/// - after that, wrapped by a device in the drive's roster (`Drive.roster`). The roster is read
///   with the keyring itself, which proves nothing alone, so that keyring must also hold every
///   key this device accepted before (`DeviceTrust.knownKeys`): only a device given the keys can
///   make one.
///
/// And never one that lacks a key it accepted before, whoever wrapped it: that's an old keyring
/// played back, which would have it seal new records with a key a removed device holds.
enum KeyTrust {
    enum Decision: Equatable {
        case accept
        case missingKnownKey
        case unknownSender
    }

    static func check(
        _ wrapped: WrappedKeyring, keyring: Keyring, device: DeviceIdentity, space: String,
        roster: (Keyring) -> [RosterEntry]?
    ) -> Decision {
        let trust = device.trust[space] ?? DeviceTrust()
        let held = Set(keyring.keys.map(\.fingerprint))
        guard trust.knownKeys.allSatisfy(held.contains) else { return .missingKnownKey }
        let sender = wrapped.sender.data
        if sender == device.publicKey.rawRepresentation { return .accept }
        if trust.knownKeys.isEmpty { return trust.approver?.data == sender ? .accept : .unknownSender }
        return roster(keyring)?.contains { $0.publicKey.data == sender } == true ? .accept : .unknownSender
    }
}

extension DeviceIdentity {
    /// This device as the roster lists it.
    var rosterEntry: RosterEntry { RosterEntry(id: id, name: name, publicKey: publicKeyBytes) }
}

/// The drive's mode, keys and devices: creating a drive, opening it on a device, approving and
/// removing devices, and the recovery key. Turning encryption on and off is in
/// `Encryption.swift`. See PLAN.md, "Encryption".
extension Drive {
    // MARK: Creating

    /// Creates the drive. Plain by default: its settings, and nothing else.
    ///
    /// Encrypted: a new drive key, this device's record (the keyring wrapped by itself, and its
    /// membership), the keyring wrapped with a new recovery key, and the settings, sealed. All in
    /// one transaction, and the drive is unlocked afterwards. It returns the recovery key, to
    /// show once. With every device lost, it's the only way back in, so only places that can show
    /// it create an encrypted drive (`atdrive login --encrypted`, the Mac app's first sign-in),
    /// never a background sync.
    ///
    /// Throws `DriveAccessError.driveExists` if the account has a drive already.
    @discardableResult
    public func create(encrypted: Bool = false) async throws -> RecoveryKey? {
        do {
            _ = try await client.createPersonalSpace(type: Lexicon.driveSpace, key: spaceKey)
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {}
        let settings = DriveSettings()
        var writes: [SpaceWrite] = []
        var keys: (keyring: Keyring, recovery: RecoveryKey, me: DeviceIdentity)?
        if encrypted {
            guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
            let keyring = Keyring(DriveKey())
            let recoveryKey = RecoveryKey()
            keys = (keyring, recoveryKey, me)
            writes = try keyWrites(keyring: keyring, recoveryKey: recoveryKey, me: me, existing: nil)
        }
        writes.insert(
            .create(
                collection: Lexicon.settings, rkey: Lexicon.settingsKey,
                value: try stored(settings, with: keys?.keyring)), at: 0)
        let cids: [String?]
        do {
            cids = try await client.applySpaceWrites(space: space, repo: owner, writes: writes)
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
            throw DriveAccessError.driveExists
        }
        if let keys {
            accept(keys.keyring, as: keys.me, settings: settings, deviceRecord: cids[2], settingsRecord: cids[0])
        } else {
            becomePlain(settings, settingsRecord: cids[0])
        }
        return keys?.recovery
    }

    /// The writes that give an encrypted drive its key records: the keyring wrapped with the
    /// recovery key, then this device's record. `existing` are the drive's key records, if it
    /// has had any: the ones left from before are replaced or deleted.
    func keyWrites(keyring: Keyring, recoveryKey: RecoveryKey, me: DeviceIdentity, existing: KeyRecords?) throws
        -> [SpaceWrite]
    {
        let recovery = try JSONValue(
            encoding: RecoveryRecord(keyring: try keyring.wrapped(for: recoveryKey, space: space)))
        let mine = try JSONValue(encoding: try deviceRecord(for: me.rosterEntry, keyring: keyring, from: me))
        var writes: [SpaceWrite] = [
            existing?.recovery == nil
                ? .create(collection: Lexicon.device, rkey: Lexicon.recoveryKey, value: recovery)
                : .update(collection: Lexicon.device, rkey: Lexicon.recoveryKey, value: recovery),
            existing?.devices[me.id] == nil
                ? .create(collection: Lexicon.device, rkey: me.id, value: mine)
                : .update(collection: Lexicon.device, rkey: me.id, value: mine),
        ]
        for id in (existing?.devices.keys.sorted() ?? []) where id != me.id {
            writes.append(.delete(collection: Lexicon.device, rkey: id))
        }
        return writes
    }

    /// A device's record holding `keyring`, wrapped for it by `sender`, and its membership sealed
    /// with the keyring's current key.
    func deviceRecord(
        for member: RosterEntry, keyring: Keyring, from sender: DeviceIdentity, existing: DeviceRecord? = nil
    ) throws -> DeviceRecord {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.publicKey.data)
        var record = existing ?? DeviceRecord(name: member.name, publicKey: member.publicKey)
        record.name = member.name
        record.publicKey = member.publicKey
        record.keyring = try keyring.wrapped(for: publicKey, from: sender.privateKey, space: space)
        record.member = try keyring.seal(member, space: space, collection: Lexicon.device, rkey: member.id)
        if member.id != sender.id { record.approvedBy = sender.id }
        return record
    }

    /// The devices approved to hold the drive's keys, as `keyring` proves them: those whose
    /// record's `member` opens with its current key, for that record, and names the record's own
    /// public key. The PDS can't add one, change one, or bring back one from before the keys last
    /// changed (removing a device changes them). It can drop one, which only locks a device out.
    func roster(_ records: KeyRecords, keyring: Keyring) -> [RosterEntry] {
        records.devices.values.compactMap { entry -> RosterEntry? in
            guard let sealed = entry.record.member, sealed.keyID == keyring.current.id,
                let member = try? keyring.current.open(
                    sealed, as: RosterEntry.self, space: space, collection: Lexicon.device, rkey: entry.id),
                member.id == entry.id, member.publicKey == entry.record.publicKey
            else { return nil }
            return member
        }.sorted { $0.id < $1.id }
    }

    // MARK: Opening

    /// Opens the drive on this device: reads whether it's encrypted and, if it is, unwraps the
    /// keyring from this device's record. From then on the drive can be written to, in the form
    /// it's in. Returns the mode.
    ///
    /// The mode is how the settings record is stored. Sealed: the drive is encrypted, and this
    /// throws `DriveAccessError` if this device hasn't been approved, or its keyring isn't one it
    /// can trust (`KeyTrust`). Plain: the drive isn't encrypted. If this device held the drive's
    /// keys, it believes that only if the settings publish them (`DriveSettings.retiredKeys`):
    /// the drive's devices do that when they turn encryption off, and the PDS, which never had
    /// the keys, can't. Otherwise this throws `encryptionRemoved`, and nothing changes.
    @discardableResult
    public func open() async throws -> DriveMode {
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        do {
            if SealedRecord.isSealed(records.settings.value) {
                try unlock(records)
                return .encrypted
            }
            guard let settings = settings(stored: records.settings.value, keyring: nil) else {
                throw DriveAccessError.damaged("settings")
            }
            if let trust = identity?.trust[space], !trust.knownKeys.isEmpty {
                let published = Set(settings.retiredKeyring?.keys.map(\.fingerprint) ?? [])
                guard trust.knownKeys.allSatisfy(published.contains) else { throw DriveAccessError.encryptionRemoved }
            }
            becomePlain(settings, settingsRecord: records.settings.cid)
            return .plain
        } catch let error as DriveAccessError {
            keys.update {
                $0.problem = error
                $0.settingsRecord = records.settings.cid
                // A drive that became encrypted is encrypted even if this device can't unlock it:
                // it must stop writing plain records.
                if $0.mode != .encrypted, SealedRecord.isSealed(records.settings.value) {
                    $0.mode = .encrypted
                    $0.keyring = nil
                    $0.retired = nil
                    $0.converting = false
                }
            }
            throw error
        }
    }

    /// Unwraps the keyring from this device's record and, if it trusts who wrapped it and the
    /// keyring opens the drive's settings, uses it from now on.
    private func unlock(_ records: KeyRecords) throws {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let entry = records.devices[me.id], entry.record.publicKey == me.publicKeyBytes else {
            throw DriveAccessError.notApproved(pending: false)
        }
        guard let wrapped = entry.record.keyring else { throw DriveAccessError.notApproved(pending: true) }
        guard let keyring = try? Keyring(unwrapping: wrapped, with: me.privateKey, space: space) else {
            throw DriveAccessError.untrustedKeyring(sender: records.name(of: wrapped.sender))
        }
        let roster = { (keyring: Keyring) in self.roster(records, keyring: keyring) }
        switch KeyTrust.check(wrapped, keyring: keyring, device: me, space: space, roster: roster) {
        case .accept: break
        case .missingKnownKey: throw DriveAccessError.keyringMissingKeys
        case .unknownSender: throw DriveAccessError.untrustedKeyring(sender: records.name(of: wrapped.sender))
        }
        // A keyring that doesn't open the settings isn't this drive's (any more).
        guard let settings = settings(stored: records.settings.value, keyring: keyring) else {
            throw DriveAccessError.untrustedKeyring(sender: records.name(of: wrapped.sender))
        }
        if let seen = me.trust[space]?.settingsGeneration, settings.generation < seen {
            throw DriveAccessError.settingsRolledBack
        }
        accept(keyring, as: me, settings: settings, deviceRecord: entry.cid, settingsRecord: records.settings.cid)
    }

    /// After an update: if the settings record or this device's record changed since the drive
    /// was opened (encryption turned on or off, or another device changed the keys), opens it
    /// again. Returns whether how records are read changed. If opening fails, things stay as
    /// they were (`accessProblem` says why): what can't be read stays unreadable, and is left
    /// alone.
    func refreshKeys(seeing snapshot: DriveSnapshot) async -> Bool {
        let before = keys.value
        // Only a drive that was opened follows changes: one told its mode or keys outright
        // (tests do that) keeps them.
        guard before.mode != nil, before.settingsRecord != nil, snapshot.revision != nil else { return false }
        let settings = snapshot.repo.cid(Lexicon.settings, Lexicon.settingsKey)
        let device = before.identity.flatMap { snapshot.repo.cid(Lexicon.device, $0.id) }
        guard settings != before.settingsRecord || device != before.deviceRecord else { return false }
        do {
            try await open()
        } catch {
            keys.update {
                $0.deviceRecord = device
                $0.settingsRecord = settings
            }
        }
        let after = keys.value
        return after.mode != before.mode || after.keyring != before.keyring || after.retired != before.retired
            || after.converting != before.converting
    }

    /// Believes the drive stopped being encrypted although its settings don't prove it
    /// (`DriveAccessError.encryptionRemoved`): forgets what this device trusted about its keys,
    /// and opens it again. The user's call, since it's what a PDS stripping the encryption would
    /// look like.
    public func acceptEncryptionRemoved() async throws {
        if var me = identity, me.trust[space] != nil {
            me.trust[space] = nil
            keys.update { $0.identity = me }
            saveIdentity?(me)
        }
        try await open()
    }

    /// Why this device couldn't follow a change to the drive's mode or keys, if it couldn't: it
    /// goes on as before, and this is worth telling the user.
    public var accessProblem: DriveAccessError? { keys.value.problem }

    /// Uses `keyring` from now on, as if unlocked with it. For tests, whose devices share one.
    func use(_ keyring: Keyring) {
        keys.update {
            $0.mode = .encrypted
            $0.keyring = keyring
        }
    }

    /// Uses `keyring` from now on, as unwrapped from this device's record at `deviceRecord`, on
    /// an encrypted drive with these settings, and remembers its keys (saving the identity if
    /// that changed what it trusts).
    func accept(
        _ keyring: Keyring, as identity: DeviceIdentity, settings: DriveSettings, deviceRecord: String?,
        settingsRecord: String?
    ) {
        var updated = identity
        var trust = (identity.trust[space] ?? DeviceTrust()).accepting(keyring)
        trust.settingsGeneration = max(trust.settingsGeneration ?? 0, settings.generation)
        updated.trust[space] = trust
        keys.update {
            $0 = DriveKeys(
                mode: .encrypted, keyring: keyring, retired: settings.converting ? settings.retiredKeyring : nil,
                converting: settings.converting, identity: updated, deviceRecord: deviceRecord,
                settingsRecord: settingsRecord)
        }
        if updated != identity { saveIdentity?(updated) }
    }

    /// Treats the drive as plain from now on: no keyring, and nothing this device trusted about
    /// its keys (if it's encrypted again, that starts over).
    func becomePlain(_ settings: DriveSettings, settingsRecord: String?) {
        var identity = self.identity
        let hadTrust = identity?.trust[space] != nil
        identity?.trust[space] = nil
        keys.update {
            $0 = DriveKeys(
                mode: .plain, retired: settings.retiredKeyring, identity: identity, settingsRecord: settingsRecord)
        }
        if hadTrust, let identity { saveIdentity?(identity) }
    }

    /// The drive's key records, on an encrypted drive this device has the keys of, read just now.
    private func unlockedRecords() async throws -> (me: DeviceIdentity, keyring: Keyring, records: KeyRecords) {
        guard try await open() == .encrypted else { throw DriveAccessError.notEncrypted }
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let keyring else { throw DriveAccessError.locked }
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        return (me, keyring, records)
    }

    /// The key records of a drive that's encrypted, whether or not this device has its keys.
    private func encryptedRecords() async throws -> KeyRecords {
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard SealedRecord.isSealed(records.settings.value) else { throw DriveAccessError.notEncrypted }
        return records
    }

    // MARK: Joining

    /// Asks for the drive's keys: writes this device's record, with its public key and no
    /// keyring, for a device that has them to approve (`approve`). What this device trusts in the
    /// drive starts over.
    public func requestAccess() async throws {
        guard var me = identity else { throw DriveAccessError.notApproved(pending: false) }
        _ = try await encryptedRecords()
        let record = DeviceRecord(name: me.name, publicKey: me.publicKeyBytes)
        do {
            try await client.putSpaceRecord(
                space: space, repo: owner, collection: Lexicon.device, rkey: me.id, record: record)
        } catch let error as XRPCError where Self.isMissing(error) {
            throw DriveAccessError.noDrive
        }
        me.trust[space] = nil
        keys.update { $0 = DriveKeys(mode: .encrypted, identity: me) }
        saveIdentity?(me)
    }

    /// A keyring wrapped for this device while it waited, and who wrapped it; `nil` while none
    /// has arrived.
    ///
    /// The sender must be in the drive's roster, as that keyring opens it. That alone proves
    /// nothing (whoever made the keyring made that roster), so the user then compares the
    /// pairing code (`code`) with what the approving device showed, and only then does
    /// `accept(_:)` take it. A keyring from a sender not in that roster is ignored, and throws
    /// `DriveAccessError.untrustedKeyring`.
    public func arrivedKeyring() async throws -> ArrivedKeyring? {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        let records = try await encryptedRecords()
        guard let entry = records.devices[me.id], entry.record.publicKey == me.publicKeyBytes else {
            throw DriveAccessError.notApproved(pending: false)
        }
        guard let wrapped = entry.record.keyring else { return nil }
        guard let keyring = try? Keyring(unwrapping: wrapped, with: me.privateKey, space: space),
            let sender = roster(records, keyring: keyring).first(where: { $0.publicKey == wrapped.sender }),
            let senderKey = try? wrapped.senderKey
        else { throw DriveAccessError.untrustedKeyring(sender: records.name(of: wrapped.sender)) }
        return ArrivedKeyring(
            sender: sender, code: PairingCode.make(for: me.publicKey, and: senderKey), cid: entry.cid)
    }

    /// Takes a keyring that arrived for this device (`arrivedKeyring`), once the user has
    /// confirmed its sender's pairing code: that device becomes the approver this one trusts for
    /// its first keyring, and the drive is unlocked with it.
    public func accept(_ arrived: ArrivedKeyring) async throws {
        guard var me = identity else { throw DriveAccessError.notApproved(pending: false) }
        me.trust[space] = DeviceTrust(approver: arrived.sender.publicKey)
        keys.update { $0.identity = me }
        saveIdentity?(me)
        try await open()
    }

    /// Sets this device up with the recovery key: unwraps the keyring from the recovery record,
    /// and writes this device's record with the keyring wrapped by itself, and its membership.
    /// Throws `DriveAccessError.wrongRecoveryKey` if the key doesn't open the recovery record.
    public func unlock(recoveryKey: RecoveryKey) async throws {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        let records = try await encryptedRecords()
        guard let recovery = records.recovery else { throw DriveAccessError.damaged("recovery record") }
        guard let keyring = try? Keyring(unwrapping: recovery.keyring, with: recoveryKey, space: space) else {
            throw DriveAccessError.wrongRecoveryKey
        }
        guard let settings = settings(stored: records.settings.value, keyring: keyring) else {
            throw DriveAccessError.damaged("settings")
        }
        let record = try JSONValue(encoding: try deviceRecord(for: me.rosterEntry, keyring: keyring, from: me))
        let cids = try await apply([
            records.devices[me.id] == nil
                ? .create(collection: Lexicon.device, rkey: me.id, value: record)
                : .update(collection: Lexicon.device, rkey: me.id, value: record)
        ])
        // The recovery key is the last word: what this device trusted before doesn't matter.
        var fresh = me
        fresh.trust[space] = nil
        accept(keyring, as: fresh, settings: settings, deviceRecord: cids[0], settingsRecord: records.settings.cid)
    }

    // MARK: Devices

    /// The drive's devices: those in its roster, and those asking to join. Approved means in the
    /// roster when this device can read it; until then, it's only what each record says. Throws
    /// `DriveAccessError.notEncrypted` on a plain drive, which has none.
    public func devices() async throws -> [DeviceInfo] {
        let records = try await encryptedRecords()
        let me = identity?.id
        let roster = keyring.map { self.roster(records, keyring: $0) }
        return records.devices.values.map { entry in
            let member = roster?.first { $0.id == entry.id }
            return DeviceInfo(
                id: entry.id, name: member?.name ?? entry.record.name, publicKey: entry.record.publicKey,
                approved: roster == nil ? entry.record.keyring != nil : member != nil, isThisDevice: entry.id == me)
        }.sorted { ($0.approved ? 0 : 1, $0.name, $0.id) < ($1.approved ? 0 : 1, $1.name, $1.id) }
    }

    /// Gives a waiting device the drive's keys: wraps the keyring for its public key, from this
    /// device, and seals its membership, in its own record. Nothing else is written, so two
    /// devices approving different devices at once both succeed.
    ///
    /// Pass the device as listed when its pairing code was shown and the user confirmed it
    /// matches: its key is the one compared, so it's the one used, whatever the record says now.
    public func approve(_ device: DeviceInfo) async throws {
        let (me, keyring, records) = try await unlockedRecords()
        let existing = records.devices[device.id]
        let member = RosterEntry(id: device.id, name: device.name, publicKey: device.publicKey)
        let value = try JSONValue(
            encoding: try deviceRecord(for: member, keyring: keyring, from: me, existing: existing?.record))
        try await apply([
            existing == nil
                ? .create(collection: Lexicon.device, rkey: device.id, value: value)
                : .update(collection: Lexicon.device, rkey: device.id, value: value)
        ])
    }

    /// Removes a device: deletes its record. If it held the drive's keys, the drive gets a new
    /// key for new records (`Keyring.rotate`), and the keyring is wrapped again, from this
    /// device, for every device left in the roster (with its membership sealed with the new key,
    /// so the removed device's is void) and for `recoveryKey`: the current one, or a new one to
    /// replace it (wrapping for the recovery key needs the key itself). The settings are sealed
    /// again too. All in one transaction. Returns whether the keyring was rotated.
    ///
    /// A device approved at the same moment by another device isn't in the roster this one read,
    /// so it's left with the old keys: it can read what was there, shows as not approved, and has
    /// to be approved again. That fails safe, rather than losing the removal.
    ///
    /// The removed device keeps what it had: the old keys, so what was sealed with them, and the
    /// first key, which names chunks. Until it's signed out of the account, it can still write,
    /// with the old keys. What it can't do is read what's sealed from now on, or have the other
    /// devices take a keyring from it once they've seen the removal.
    @discardableResult
    public func remove(_ id: String, recoveryKey: RecoveryKey?) async throws -> Bool {
        let (me, keyring, records) = try await unlockedRecords()
        guard id != me.id else { throw DriveAccessError.cannotRemoveThisDevice }
        guard var settings = settings(stored: records.settings.value, keyring: keyring) else {
            throw DriveAccessError.damaged("settings")
        }
        var members = roster(records, keyring: keyring)
        let heldKeys = members.contains { $0.id == id } || records.devices[id]?.record.keyring != nil
        guard heldKeys else {
            guard records.devices[id] != nil else { throw DriveAccessError.noSuchDevice(id) }
            try await apply([.delete(collection: Lexicon.device, rkey: id)])
            return false
        }
        guard let recoveryKey else { throw DriveAccessError.recoveryKeyNeeded }
        var rotated = keyring
        rotated.rotate()
        members.removeAll { $0.id == id }
        if !members.contains(where: { $0.id == me.id }) { members.append(me.rosterEntry) }
        settings.generation += 1

        var writes: [SpaceWrite] = []
        if records.devices[id] != nil { writes.append(.delete(collection: Lexicon.device, rkey: id)) }
        var mine = 0
        for member in members {
            let existing = records.devices[member.id]
            let value = try JSONValue(
                encoding: try deviceRecord(for: member, keyring: rotated, from: me, existing: existing?.record))
            if member.id == me.id { mine = writes.count }
            writes.append(
                existing == nil
                    ? .create(collection: Lexicon.device, rkey: member.id, value: value)
                    : .update(collection: Lexicon.device, rkey: member.id, value: value))
        }
        let recovery = try JSONValue(
            encoding: RecoveryRecord(keyring: try rotated.wrapped(for: recoveryKey, space: space)))
        writes.append(
            records.recovery == nil
                ? .create(collection: Lexicon.device, rkey: Lexicon.recoveryKey, value: recovery)
                : .update(collection: Lexicon.device, rkey: Lexicon.recoveryKey, value: recovery))
        let settingsWrite = writes.count
        writes.append(
            .update(collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: rotated))
        )
        let cids = try await apply(writes)
        accept(rotated, as: me, settings: settings, deviceRecord: cids[mine], settingsRecord: cids[settingsWrite])
        return true
    }

    // MARK: The recovery key

    /// Whether `key` is the drive's recovery key: it opens the recovery record.
    public func isRecoveryKey(_ key: RecoveryKey) async throws -> Bool {
        let records = try await encryptedRecords()
        guard let recovery = records.recovery else { return false }
        return (try? Keyring(unwrapping: recovery.keyring, with: key, space: space)) != nil
    }

    /// Wraps the keyring with a new recovery key, replacing the old one, which stops working.
    /// Returns the new key, to show once (or make it first, and show it before it's in effect).
    @discardableResult
    public func replaceRecoveryKey(with recoveryKey: RecoveryKey = RecoveryKey()) async throws -> RecoveryKey {
        let (_, keyring, _) = try await unlockedRecords()
        let record = RecoveryRecord(keyring: try keyring.wrapped(for: recoveryKey, space: space))
        do {
            try await client.putSpaceRecord(
                space: space, repo: owner, collection: Lexicon.device, rkey: Lexicon.recoveryKey, record: record)
        } catch let error as XRPCError where Self.isMissing(error) {
            throw DriveAccessError.noDrive
        }
        return recoveryKey
    }

    // MARK: Records

    /// The settings record, every device record and the recovery record, as stored; `nil` if
    /// the drive doesn't exist (it has no settings).
    func keyRecords() async throws -> KeyRecords? {
        guard let settings = try await settingsRecord() else { return nil }
        var devices: [String: DeviceEntry] = [:]
        var recovery: RecoveryRecord?
        var cursor: String?
        repeat {
            let page: XRPCClient.SpaceRecordPage<JSONValue>
            do {
                page = try await client.listRawSpaceRecords(
                    space: space, repo: owner, collection: Lexicon.device, cursor: cursor)
            } catch let error as XRPCError where Self.isMissing(error) {
                return nil
            }
            for item in page.records {
                guard let value = item.value else { continue }
                if item.rkey == Lexicon.recoveryKey {
                    recovery = try? value.decode(as: RecoveryRecord.self)
                } else if let record = try? value.decode(as: DeviceRecord.self) {
                    devices[item.rkey] = DeviceEntry(id: item.rkey, cid: item.cid, record: record)
                }
            }
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return KeyRecords(settings: settings, devices: devices, recovery: recovery)
    }
}

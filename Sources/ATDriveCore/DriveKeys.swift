import Crypto
import Foundation

/// The drive's keys on this device (`Drive.keys`).
struct DriveKeys: Sendable {
    var keyring: Keyring?
    var identity: DeviceIdentity?
    /// The CID of this device's record when its keyring was last unwrapped (or that was tried):
    /// when the record changes, `refreshKeys` unwraps it again.
    var deviceRecord: String?
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
    /// It holds the drive's keys: it's in the roster. Without the keys to read the roster, its
    /// record says so, which proves nothing.
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
/// - after that, wrapped by a device in the drive's roster. The roster is read with the keyring
///   itself, which proves nothing alone, so that keyring must also hold every key this device
///   accepted before (`DeviceTrust.knownKeys`): only a device given the keys can make one.
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
        let trust = device.trust.about(space)
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

    /// Its device record, holding `keyring` wrapped by itself.
    func record(holding keyring: Keyring) throws -> DeviceRecord {
        DeviceRecord(
            name: name, publicKey: publicKeyBytes, keyring: try keyring.wrapped(for: publicKey, from: privateKey))
    }
}

/// The drive's keys and devices: creating a drive, opening it on a device, approving and removing
/// devices, and the recovery key. See PLAN.md, "Step 3: encryption".
extension Drive {
    // MARK: Creating

    /// Creates the drive, encrypted: a new drive key, this device's record (the keyring wrapped by
    /// itself), the keyring wrapped with a new recovery key, and the settings, sealed, with this
    /// device in the roster. All in one transaction, and the drive is unlocked afterwards.
    ///
    /// Returns the recovery key, to show once. With every device lost, it's the only way back in,
    /// so only places that can show it create a drive (`atdrive login`, the Mac app's first
    /// sign-in), never a background sync. Throws `DriveAccessError.driveExists` if the account has
    /// a drive already.
    public func create() async throws -> RecoveryKey {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        do {
            _ = try await client.createPersonalSpace(type: Lexicon.driveSpace, key: spaceKey)
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {}
        let keyring = Keyring(DriveKey())
        let recoveryKey = RecoveryKey()
        let settings = DriveSettings(roster: [me.rosterEntry])
        let writes: [SpaceWrite] = [
            .create(
                collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: keyring)),
            .create(
                collection: Lexicon.device, rkey: Lexicon.recoveryKey,
                value: try JSONValue(encoding: RecoveryRecord(keyring: try keyring.wrapped(for: recoveryKey)))),
            .create(
                collection: Lexicon.device, rkey: me.id, value: try JSONValue(encoding: me.record(holding: keyring))),
        ]
        let cids: [String?]
        do {
            cids = try await client.applySpaceWrites(space: space, repo: owner, writes: writes)
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
            throw DriveAccessError.driveExists
        }
        accept(keyring, as: me, deviceRecord: cids[2])
        return recoveryKey
    }

    // MARK: Opening

    /// Opens the drive's keys on this device: unwraps the keyring from its device record and, if
    /// it trusts who wrapped it (`KeyTrust`), uses it from now on. What it trusts is updated and
    /// saved. Throws `DriveAccessError` if there's no drive, this device hasn't been approved, or
    /// the keyring isn't one it can trust (it's ignored then).
    @discardableResult
    public func unlock() async throws -> Keyring {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard let entry = records.devices[me.id], entry.record.publicKey == me.publicKeyBytes else {
            throw DriveAccessError.notApproved(pending: false)
        }
        guard let wrapped = entry.record.keyring else { throw DriveAccessError.notApproved(pending: true) }
        guard let keyring = try? Keyring(unwrapping: wrapped, with: me.privateKey) else {
            throw DriveAccessError.untrustedKeyring(sender: records.name(of: wrapped.sender))
        }
        let roster = { (keyring: Keyring) in self.readSettings(records.settings.value, with: keyring)?.roster }
        switch KeyTrust.check(wrapped, keyring: keyring, device: me, space: space, roster: roster) {
        case .accept: break
        case .missingKnownKey: throw DriveAccessError.keyringMissingKeys
        case .unknownSender: throw DriveAccessError.untrustedKeyring(sender: records.name(of: wrapped.sender))
        }
        accept(keyring, as: me, deviceRecord: entry.cid)
        return keyring
    }

    /// After an update: if this device's record changed since its keyring was unwrapped (another
    /// device rotated the keyring, say), unwraps it again. Returns whether the keyring changed. If
    /// that fails, the keyring stays as it was: what's sealed with a key it lacks stays
    /// unreadable, and is left alone.
    func refreshKeys(seeing snapshot: DriveSnapshot) async -> Bool {
        let before = keys.value
        guard let identity = before.identity, snapshot.revision != nil else { return false }
        let cid = snapshot.repo.cid(Lexicon.device, identity.id)
        guard cid != before.deviceRecord else { return false }
        do {
            try await unlock()
        } catch {
            keys.update { $0.deviceRecord = cid }
        }
        return keyring != before.keyring
    }

    /// Uses `keyring` from now on, as if unlocked with it. For tests, whose devices share one.
    func use(_ keyring: Keyring) {
        keys.update { $0.keyring = keyring }
    }

    /// Uses `keyring` from now on, as unwrapped from this device's record at `deviceRecord`, and
    /// remembers its keys (saving the identity if that changed what it trusts).
    private func accept(_ keyring: Keyring, as identity: DeviceIdentity, deviceRecord: String?) {
        var updated = identity
        updated.trust = identity.trust.accepting(keyring, in: space)
        keys.update { $0 = DriveKeys(keyring: keyring, identity: updated, deviceRecord: deviceRecord) }
        if updated != identity { saveIdentity?(updated) }
    }

    // MARK: Joining

    /// Asks for the drive's keys: writes this device's record, with its public key and no
    /// keyring, for a device that has them to approve (`approve`). What this device trusts in the
    /// drive starts over.
    public func requestAccess() async throws {
        guard var me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard try await settingsRecord() != nil else { throw DriveAccessError.noDrive }
        let record = DeviceRecord(name: me.name, publicKey: me.publicKeyBytes)
        do {
            try await client.putSpaceRecord(
                space: space, repo: owner, collection: Lexicon.device, rkey: me.id, record: record)
        } catch let error as XRPCError where Self.isMissing(error) {
            throw DriveAccessError.noDrive
        }
        me.trust = DeviceTrust(space: space)
        keys.update { $0 = DriveKeys(keyring: nil, identity: me, deviceRecord: nil) }
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
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard let entry = records.devices[me.id], entry.record.publicKey == me.publicKeyBytes else {
            throw DriveAccessError.notApproved(pending: false)
        }
        guard let wrapped = entry.record.keyring else { return nil }
        guard let keyring = try? Keyring(unwrapping: wrapped, with: me.privateKey),
            let sender = readSettings(records.settings.value, with: keyring)?.member(wrapped.sender.data),
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
        me.trust = DeviceTrust(space: space, approver: arrived.sender.publicKey)
        keys.update { $0.identity = me }
        saveIdentity?(me)
        try await unlock()
    }

    /// Sets this device up with the recovery key: unwraps the keyring from the recovery record,
    /// writes this device's record with the keyring wrapped by itself, and adds it to the roster.
    /// Throws `DriveAccessError.wrongRecoveryKey` if the key doesn't open the recovery record.
    public func unlock(recoveryKey: RecoveryKey) async throws {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard let recovery = records.recovery else { throw DriveAccessError.damaged("recovery record") }
        guard let keyring = try? Keyring(unwrapping: recovery.keyring, with: recoveryKey) else {
            throw DriveAccessError.wrongRecoveryKey
        }
        guard var settings = readSettings(records.settings.value, with: keyring) else {
            throw DriveAccessError.damaged("settings")
        }
        settings.roster.removeAll { $0.id == me.id }
        settings.roster.append(me.rosterEntry)
        let record = try JSONValue(encoding: me.record(holding: keyring))
        let cids = try await apply([
            records.devices[me.id] == nil
                ? .create(collection: Lexicon.device, rkey: me.id, value: record)
                : .update(collection: Lexicon.device, rkey: me.id, value: record),
            .update(
                collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: keyring)),
        ])
        // The recovery key is the last word: what this device trusted before doesn't matter.
        var fresh = me
        fresh.trust = DeviceTrust(space: space)
        accept(keyring, as: fresh, deviceRecord: cids[0])
    }

    // MARK: Devices

    /// The drive's devices: those in its roster, and those asking to join. Approved means in the
    /// roster when this device can read it; until then, it's only what each record says.
    public func devices() async throws -> [DeviceInfo] {
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        let me = identity?.id
        let roster = keyring.flatMap { readSettings(records.settings.value, with: $0) }?.roster
        var devices = records.devices.values.map { entry in
            let member = roster?.first { $0.id == entry.id && $0.publicKey == entry.record.publicKey }
            return DeviceInfo(
                id: entry.id, name: member?.name ?? entry.record.name, publicKey: entry.record.publicKey,
                approved: roster == nil ? entry.record.keyring != nil : member != nil, isThisDevice: entry.id == me)
        }
        for member in roster ?? [] where records.devices[member.id] == nil {
            devices.append(
                DeviceInfo(
                    id: member.id, name: member.name, publicKey: member.publicKey, approved: true,
                    isThisDevice: member.id == me))
        }
        return devices.sorted { ($0.approved ? 0 : 1, $0.name, $0.id) < ($1.approved ? 0 : 1, $1.name, $1.id) }
    }

    /// Gives a waiting device the drive's keys: wraps the keyring for its public key, from this
    /// device, and adds it to the roster.
    ///
    /// Pass the device as listed when its pairing code was shown and the user confirmed it
    /// matches: its key is the one compared, so it's the one used, whatever the record says now.
    public func approve(_ device: DeviceInfo) async throws {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let keyring else { throw DriveAccessError.locked }
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard var settings = readSettings(records.settings.value) else { throw DriveAccessError.damaged("settings") }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey.data)
        settings.roster.removeAll { $0.id == device.id }
        settings.roster.append(RosterEntry(id: device.id, name: device.name, publicKey: device.publicKey))
        let existing = records.devices[device.id]
        var record = existing?.record ?? DeviceRecord(name: device.name, publicKey: device.publicKey)
        record.publicKey = device.publicKey
        record.keyring = try keyring.wrapped(for: publicKey, from: me.privateKey)
        record.approvedBy = me.id
        let value = try JSONValue(encoding: record)
        try await apply([
            existing == nil
                ? .create(collection: Lexicon.device, rkey: device.id, value: value)
                : .update(collection: Lexicon.device, rkey: device.id, value: value),
            .update(
                collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: keyring)),
        ])
    }

    /// Removes a device: deletes its record and takes it off the roster. If it held the drive's
    /// keys, the drive gets a new key for new records (`Keyring.rotate`), and the keyring is
    /// wrapped again, from this device, for every device left in the roster and for
    /// `recoveryKey`: the current one, or a new one to replace it (wrapping for the recovery key
    /// needs the key itself). All in one transaction. Returns whether the keyring was rotated.
    ///
    /// The removed device keeps what it had: the old keys, so what was sealed with them, and the
    /// first key, which names chunks. Until it's signed out of the account, it can still write,
    /// with the old keys. What it can't do is read what's sealed from now on, or have the other
    /// devices take a keyring from it once they've seen the removal.
    @discardableResult
    public func remove(_ id: String, recoveryKey: RecoveryKey?) async throws -> Bool {
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let keyring else { throw DriveAccessError.locked }
        guard id != me.id else { throw DriveAccessError.cannotRemoveThisDevice }
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard var settings = readSettings(records.settings.value) else { throw DriveAccessError.damaged("settings") }
        let heldKeys = settings.roster.contains { $0.id == id } || records.devices[id]?.record.keyring != nil
        guard heldKeys else {
            guard records.devices[id] != nil else { throw DriveAccessError.noSuchDevice(id) }
            try await apply([.delete(collection: Lexicon.device, rkey: id)])
            return false
        }
        guard let recoveryKey else { throw DriveAccessError.recoveryKeyNeeded }
        var rotated = keyring
        rotated.rotate()
        settings.roster.removeAll { $0.id == id }
        if !settings.roster.contains(where: { $0.id == me.id }) { settings.roster.append(me.rosterEntry) }

        var writes: [SpaceWrite] = []
        if records.devices[id] != nil { writes.append(.delete(collection: Lexicon.device, rkey: id)) }
        var mine = 0
        for member in settings.roster {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.publicKey.data)
            let existing = records.devices[member.id]
            var record = existing?.record ?? DeviceRecord(name: member.name, publicKey: member.publicKey)
            record.publicKey = member.publicKey
            record.keyring = try rotated.wrapped(for: publicKey, from: me.privateKey)
            let value = try JSONValue(encoding: record)
            if member.id == me.id { mine = writes.count }
            writes.append(
                existing == nil
                    ? .create(collection: Lexicon.device, rkey: member.id, value: value)
                    : .update(collection: Lexicon.device, rkey: member.id, value: value))
        }
        let recovery = try JSONValue(encoding: RecoveryRecord(keyring: try rotated.wrapped(for: recoveryKey)))
        writes.append(
            records.recovery == nil
                ? .create(collection: Lexicon.device, rkey: Lexicon.recoveryKey, value: recovery)
                : .update(collection: Lexicon.device, rkey: Lexicon.recoveryKey, value: recovery))
        writes.append(
            .update(collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: rotated))
        )
        let cids = try await apply(writes)
        accept(rotated, as: me, deviceRecord: cids[mine])
        return true
    }

    // MARK: The recovery key

    /// Whether `key` is the drive's recovery key: it opens the recovery record.
    public func isRecoveryKey(_ key: RecoveryKey) async throws -> Bool {
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        guard let recovery = records.recovery else { return false }
        return (try? Keyring(unwrapping: recovery.keyring, with: key)) != nil
    }

    /// Wraps the keyring with a new recovery key, replacing the old one, which stops working.
    /// Returns the new key, to show once (or make it first, and show it before it's in effect).
    @discardableResult
    public func replaceRecoveryKey(with recoveryKey: RecoveryKey = RecoveryKey()) async throws -> RecoveryKey {
        guard let keyring else { throw DriveAccessError.locked }
        let record = RecoveryRecord(keyring: try keyring.wrapped(for: recoveryKey))
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

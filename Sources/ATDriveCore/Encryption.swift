import Crypto
import Foundation

/// Where a drive stands between plain and encrypted (`Drive.encryptionStatus`).
public struct EncryptionStatus: Sendable, Equatable {
    public var mode: DriveMode
    /// Records that aren't stored the way the drive now stores them: plain (or sealed with keys
    /// since published) on an encrypted drive, sealed on a plain one. `Drive.convert` rewrites
    /// them.
    public var pending: Int
    /// The file contents among them that have to be downloaded and uploaded again, in bytes.
    public var pendingBytes: Int
    /// Encrypted drives: whether such records are still read (`DriveSettings.converting`).
    public var converting: Bool
    /// Encrypted drives: whether its keys were replaced and what's sealed with the old ones is
    /// still being sealed again (`DriveSettings.rotating`). Those records count as `pending`.
    public var rotating: Bool = false
    /// Encrypted drives that have finished converting: records that aren't sealed with the
    /// drive's keys, so they're ignored. A device that hadn't noticed encryption was turned on
    /// wrote them, or the PDS did. `Drive.convert(adoptUnsealed:)` encrypts and keeps them.
    public var unsealed: Int
    /// Records this device can't read for another reason (a key it lacks, a newer format).
    /// They're left as they are.
    public var unreadable: Int

    /// Nothing left to convert.
    public var isSettled: Bool { pending == 0 && !converting && !rotating }
}

/// Turning encryption on and off. See PLAN.md, "Encryption".
///
/// Both flip the drive's settings record, which is what says whether a drive is encrypted, and
/// everything written afterwards follows. What's already there is handled differently each way:
///
/// - **Off** publishes the drive's keys in the (now plain) settings. Everything sealed with them
///   stays readable, by every device and by the PDS, without rewriting anything, so turning
///   encryption off is one write. `convert` then rewrites records as plain ones, which only
///   matters to clients that can't decrypt.
/// - **On** makes new keys. What's there is still plain, so `convert` has to rewrite every record
///   and upload every file again, encrypted: that's the expensive part. Until it's done the drive
///   says it's `converting`, and devices go on reading the plain records.
///
/// `convert` can be interrupted and run again, on any device with the keys.
extension Drive {
    // MARK: Turning encryption on and off

    /// Turns encryption on: new keys, this device's record, a new recovery key (returned, to show
    /// once), and the settings sealed, saying the drive is `converting`. One transaction. Other
    /// devices have to be approved again (or use the recovery key) to go on reading and writing.
    ///
    /// What's in the drive is still plain afterwards: run `convert` to encrypt it. The PDS has
    /// had it in the clear, so this protects it from now on, not from copies already made.
    ///
    /// The settings sealed are the plain ones (`settingsToSeal`): `retentionDays` is how long to
    /// keep history, if the user typed it.
    ///
    /// Two devices turning it on at once: one wins, and the other gets `alreadyEncrypted` (and
    /// has to be approved), having written nothing.
    public func enableEncryption(retentionDays: Int? = nil) async throws -> RecoveryKey {
        try await retryingSettingsRaces { try await turnEncryptionOn(retentionDays: retentionDays) }
    }

    private func turnEncryptionOn(retentionDays: Int?) async throws -> RecoveryKey {
        let mode: DriveMode
        do {
            mode = try await open()
        } catch is DriveAccessError where keys.value.mode == .encrypted {
            // Encrypted, by another device (this one doesn't have the keys yet).
            throw DriveAccessError.alreadyEncrypted
        }
        guard mode == .plain else { throw DriveAccessError.alreadyEncrypted }
        guard let me = identity else { throw DriveAccessError.notApproved(pending: false) }
        guard let records = try await keyRecords(),
            let plain = settings(stored: records.settings.value, keyring: nil)
        else { throw DriveAccessError.damaged("settings") }
        var settings = Self.settingsToSeal(plain, retentionDays: retentionDays)
        settings.converting = true
        settings.rotating = false
        settings.formerKeys = []
        settings.generation += 1
        // The sharing key was readable until now: a new one is made (`ensureSharingKey`).
        settings.sharingKey = nil
        let keyring = Keyring(DriveKey())
        let recoveryKey = RecoveryKey()
        let writes =
            [
                SpaceWrite.update(
                    collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: keyring))
            ] + (try keyWrites(keyring: keyring, recoveryKey: recoveryKey, me: me, existing: records))
        let cids = try await applyChangingSettings(writes, generation: settings.generation, read: records.settings)
        accept(keyring, as: me, settings: settings, deviceRecord: cids[2], settingsRecord: cids[0])
        return recoveryKey
    }

    /// The settings that turning encryption on would seal, for showing first: the plain ones,
    /// which the PDS could have changed. Once sealed, every device trusts them, so a retention
    /// shorter than `DriveSettings.minimumUntypedRetentionDays` isn't taken from there: the
    /// default is sealed instead, unless the user typed one (`retentionDays`).
    public func settingsToSeal(retentionDays: Int? = nil) async throws -> DriveSettings {
        guard try await open() == .plain else { throw DriveAccessError.alreadyEncrypted }
        guard let record = try await settingsRecord(), let plain = settings(stored: record.value, keyring: nil) else {
            throw DriveAccessError.damaged("settings")
        }
        return Self.settingsToSeal(plain, retentionDays: retentionDays)
    }

    static func settingsToSeal(_ plain: DriveSettings, retentionDays: Int?) -> DriveSettings {
        var settings = plain
        if let retentionDays {
            settings.retentionDays = max(retentionDays, 1)
        } else if settings.retentionDays < DriveSettings.minimumUntypedRetentionDays {
            settings.retentionDays = DriveSettings.defaultRetentionDays
        }
        return settings
    }

    /// Turns encryption off: the settings become plain and publish the drive's keys, and the
    /// device records and the recovery record are deleted. One transaction, and nothing else is
    /// rewritten: what's sealed stays readable with the published keys, to every device and to
    /// whoever runs the PDS. It can't be taken back for what's already there.
    ///
    /// The published keys are also how the drive's other devices know this wasn't the PDS's
    /// doing (`open`).
    public func disableEncryption() async throws {
        try await retryingSettingsRaces { try await turnEncryptionOff() }
    }

    private func turnEncryptionOff() async throws {
        guard try await open() == .encrypted else { throw DriveAccessError.notEncrypted }
        guard let keyring else { throw DriveAccessError.locked }
        guard let records = try await keyRecords() else { throw DriveAccessError.noDrive }
        // Changed since `open`: the keyring may not be theirs.
        guard records.settings.cid == keys.value.settingsRecord else { throw DriveAccessError.settingsChanged }
        guard var settings = settings(stored: records.settings.value, keyring: keyring) else {
            throw DriveAccessError.damaged("settings")
        }
        settings.converting = false
        settings.rotating = false
        // Only of use on an encrypted drive, and they'd be readable.
        settings.formerKeys = []
        settings.generation += 1
        // It would be readable from now on: a new one is made (`ensureSharingKey`).
        settings.sharingKey = nil
        for key in keyring.keys.map({ Bytes($0.rawRepresentation) }) where !settings.retiredKeys.contains(key) {
            settings.retiredKeys.append(key)
        }
        var writes: [SpaceWrite] = [
            .update(collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: nil))
        ]
        if records.recoveryStored { writes.append(.delete(collection: Lexicon.device, rkey: Lexicon.recoveryKey)) }
        for id in records.devices.keys.sorted() { writes.append(.delete(collection: Lexicon.device, rkey: id)) }
        let cids = try await applyChangingSettings(writes, generation: settings.generation, read: records.settings)
        becomePlain(settings, settingsRecord: cids[0])
    }

    // MARK: Converting what's there

    /// Where the drive stands: its mode, and how much is left to convert. Lists the whole drive.
    public func encryptionStatus() async throws -> EncryptionStatus {
        let mode = try await open()
        return try await survey(mode).status(mode, keys: keys.value)
    }

    /// What converting would have to do if the drive were switched to `mode`: for a warning
    /// before turning encryption on, which stores every file again. Lists the whole drive.
    public func conversionEstimate(to mode: DriveMode) async throws -> EncryptionStatus {
        _ = try await open()
        let current = keys.value.mode
        // Nothing is under the keys an encrypted drive would get, so everything counts.
        return try await survey(mode, firstKey: current == mode ? keyring?.keys.first?.id : nil)
            .status(mode, keys: nil)
    }

    /// What converting would have to do if the drive's keys were replaced (`rotateKeys`): all of
    /// it, since nothing is sealed with a key that doesn't exist yet. Lists the whole drive.
    public func rotationEstimate() async throws -> EncryptionStatus {
        guard try await open() == .encrypted else { throw DriveAccessError.notEncrypted }
        return try await survey(.encrypted, firstKey: nil).status(.encrypted, keys: nil)
    }

    /// Rewrites everything that isn't stored the way the drive now stores things: each record
    /// in the drive's form and, where a file's chunks aren't (plain chunks on an encrypted drive,
    /// encrypted ones on a plain drive, or ones encrypted with keys since published), its
    /// contents downloaded and stored again. History is converted too. On an encrypted drive,
    /// once nothing is left, the drive stops `converting`: from then on its devices ignore
    /// records that aren't sealed with its keys.
    ///
    /// Safe to interrupt and to run again, from any device that has the keys; it picks up what's
    /// left. Versions keep their IDs, so history reads the same afterwards. If another device
    /// changes a file at the very moment its record is rewritten, the change shows up as a race
    /// and is settled like one (a conflicted copy at worst): nothing is lost.
    ///
    /// `adoptUnsealed`: on an encrypted drive that had finished converting, also take in records
    /// that aren't sealed with its keys (`EncryptionStatus.unsealed`). They could have been
    /// written by the PDS, so that's the user's call.
    ///
    /// `progress` reports records done, of those to do.
    @discardableResult
    public func convert(
        adoptUnsealed: Bool = false, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> EncryptionStatus {
        let mode = try await open()
        if mode == .encrypted, keyring == nil { throw DriveAccessError.locked }
        var found = try await survey(mode)
        if mode == .encrypted, adoptUnsealed, found.unsealed > 0, !keys.value.converting {
            guard try await setConverting(true) else { throw DriveAccessError.settingsChanged }
            found = try await survey(mode)
        }
        var done = 0
        var total = found.pending
        // Another device can change the keys meanwhile (`rotateKeys`): then there's more to do,
        // under its keys, before converting is done.
        for _ in 0..<3 {
            // A pass can leave work behind (a record another device rewrote meanwhile), so it's
            // surveyed again, a few times at most.
            for _ in 0..<4 where found.pending > 0 {
                let before = found.pending
                try await convert(found, mode: mode) {
                    done += 1
                    progress?(min(done, total), total)
                }
                found = try await survey(mode)
                if found.pending >= before { break }
            }
            guard mode == .encrypted, found.pending == 0, keys.value.converting || keys.value.rotating,
                try await !setConverting(false)
            else { break }
            guard try await open() == mode else { break }
            found = try await survey(mode)
            total = done + found.pending
        }
        return found.status(mode, keys: keys.value)
    }

    /// Sets an encrypted drive's `converting` flag, in its sealed settings. Turning it off ends
    /// rotating too, once everything is sealed with the current keys: the retired keys are
    /// dropped (`DriveSettings.forgetRetiredKeys`), and nothing sealed with them is read again.
    ///
    /// Only if the settings are the ones the drive was opened with, which the survey went by:
    /// returns `false`, having written nothing, if another device changed them since. Open the
    /// drive and survey it again.
    @discardableResult
    private func setConverting(_ converting: Bool) async throws -> Bool {
        guard let me = identity, let keyring, let record = try await settingsRecord() else {
            throw DriveAccessError.damaged("settings")
        }
        guard record.cid == keys.value.settingsRecord else { return false }
        guard var settings = settings(stored: record.value, keyring: keyring) else {
            throw DriveAccessError.damaged("settings")
        }
        settings.converting = converting
        if !converting {
            settings.rotating = false
            settings.forgetRetiredKeys()
        }
        settings.generation += 1
        let cids: [String?]
        do {
            cids = try await applyChangingSettings(
                [
                    .update(
                        collection: Lexicon.settings, rkey: Lexicon.settingsKey,
                        value: try stored(settings, with: keyring))
                ], generation: settings.generation, read: record)
        } catch DriveAccessError.settingsChanged {
            return false
        }
        accept(keyring, as: me, settings: settings, deviceRecord: keys.value.deviceRecord, settingsRecord: cids[0])
        return true
    }

    /// Every record of the drive as stored, and how each stands against the drive's mode.
    struct Survey {
        struct Contents {
            /// The version holding the chunk list; `nil` for a node whose holder is gone.
            var version: Version?
            /// The nodes whose current contents are that version's.
            var nodes: [Node]
            var chunks: [ChunkRef]
            var name: String
            var size: Int
            var sha256: String?
        }
        /// Chunk lists to store again, each with the records that hold it.
        var contents: [Contents] = []
        /// Records to store again as they are, in the drive's form.
        var nodes: [Node] = []
        var versions: [Version] = []
        /// `chunks` records to store again as they are: their key, and the part they hold.
        var parts: [(key: String, chunks: [ChunkRef])] = []
        var unsealed = 0
        var unreadable = 0
        /// The CIDs of the chunks in records that need nothing: uploads can skip those.
        var known: Set<String> = []

        var pending: Int {
            contents.reduce(0) { $0 + ($1.version == nil ? 0 : 1) + $1.nodes.count } + nodes.count + versions.count
                + parts.count
        }

        /// `keys`: how the drive reads its records now; `nil` for an estimate.
        func status(_ mode: DriveMode, keys: DriveKeys?) -> EncryptionStatus {
            EncryptionStatus(
                mode: mode, pending: pending, pendingBytes: contents.reduce(0) { $0 + $1.size },
                converting: keys?.converting ?? false, rotating: keys?.rotating ?? false, unsealed: unsealed,
                unreadable: unreadable)
        }
    }

    private func survey(_ mode: DriveMode) async throws -> Survey {
        try await survey(mode, firstKey: keyring?.keys.first?.id)
    }

    /// `firstKey` is the key chunks have to be named with to count as encrypted.
    private func survey(_ mode: DriveMode, firstKey: KeyID?) async throws -> Survey {
        var listing: [XRPCClient.SpaceRecordPage<JSONValue>.Record] = []
        var cursor: String?
        repeat {
            let page: XRPCClient.SpaceRecordPage<JSONValue>
            do {
                page = try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil, cursor: cursor)
            } catch let error as XRPCError where Self.isMissing(error) {
                throw DriveAccessError.noDrive
            }
            listing += page.records
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil

        func chunksConform(_ chunks: [ChunkRef]?) -> Bool {
            (chunks ?? []).allSatisfy { mode == .encrypted ? $0.isEncrypted && $0.key == firstKey : !$0.isEncrypted }
        }
        func formConforms(_ form: StoredForm?) -> Bool {
            mode == .encrypted ? firstKey != nil && form?.isCurrent == true : form == .plain
        }

        var continuations: [String: JSONValue] = [:]
        for record in listing where record.collection == Lexicon.chunks { continuations[record.rkey] = record.value }
        var found = Survey()
        func count(_ reason: UnreadableNode.Reason) {
            if reason == .notSealed { found.unsealed += 1 } else { found.unreadable += 1 }
        }
        var versions: [String: (version: Version, conforms: Bool)] = [:]
        var nodes: [(node: Node, conforms: Bool)] = []
        for record in listing {
            let form = { self.storedForm(of: record.value, collection: record.collection ?? "", rkey: record.rkey) }
            switch record.collection {
            case Lexicon.version:
                switch readVersion(id: record.rkey, cid: record.cid, value: record.value, continuations: continuations)
                {
                case .readable(let version): versions[version.id] = (version, formConforms(form()))
                case .unreadable(let version): count(version.reason)
                }
            case Lexicon.node:
                switch readNode(id: record.rkey, cid: record.cid, value: record.value, continuations: continuations) {
                case .readable(let node): nodes.append((node, formConforms(form())))
                case .unreadable(let node): count(node.reason)
                }
            default: break
            }
        }
        // Chunk lists that have to be stored again, by the version that holds them.
        var groups: [String: Survey.Contents] = [:]
        for (id, entry) in versions {
            let record = entry.version.record
            guard record.contentsFrom == nil, let chunks = record.chunks, !chunksConform(chunks) else { continue }
            groups[id] = Survey.Contents(
                version: entry.version, nodes: [], chunks: chunks, name: record.name ?? id,
                size: record.size ?? chunks.reduce(0) { $0 + $1.size }, sha256: record.sha256)
        }
        var replacedParts: Set<String> = []
        for (node, conforms) in nodes {
            let record = node.record
            if !chunksConform(record.chunks) {
                if let holder = record.contentsFrom, groups[holder] != nil {
                    groups[holder]?.nodes.append(node)
                } else if record.hasContinuations {
                    found.unreadable += 1  // its chunk list's records belong to a version that's gone
                } else {
                    found.contents.append(
                        Survey.Contents(
                            version: nil, nodes: [node], chunks: record.chunks ?? [], name: record.name,
                            size: record.size ?? 0, sha256: record.sha256))
                }
            } else if !conforms {
                found.nodes.append(node)
            } else {
                for chunk in record.chunks ?? [] { found.known.insert(chunk.cid) }
            }
        }
        for (id, entry) in versions where groups[id] == nil {
            if entry.conforms {
                for chunk in entry.version.record.chunks ?? [] { found.known.insert(chunk.cid) }
            } else {
                found.versions.append(entry.version)
            }
        }
        for (id, group) in groups {
            let record = group.version!.record
            let first = max(record.continuationsFrom ?? 1, 1)
            for index in first..<(first + (record.continuations ?? 0)) {
                replacedParts.insert(Lexicon.continuationKey(of: id, index))
            }
        }
        found.contents += groups.values.sorted { ($0.version?.id ?? "") < ($1.version?.id ?? "") }
        // `chunks` records that stay, but aren't in the drive's form.
        for (key, value) in continuations.sorted(by: { $0.key < $1.key }) where !replacedParts.contains(key) {
            guard
                let (payload, blobs, form) = try? unseal(
                    value, as: ChunksPayload.self, collection: Lexicon.chunks, rkey: key),
                let paired = ChunkRef.pair(blobs, payload.chunkIDs, key: payload.chunkKey), let part = paired
            else { continue }
            if !formConforms(form) { found.parts.append((key, part)) }
        }
        return found
    }

    /// One pass over what a survey found. `step` is called for each record rewritten or given up
    /// on.
    private func convert(_ found: Survey, mode: DriveMode, step: () -> Void) async throws {
        var known = found.known
        for group in found.contents {
            do {
                try await restore(group, known: &known)
            } catch let error where Self.isMissingBlob(error) {
                // A chunk we meant to reuse was deleted meanwhile: upload everything.
                var none: Set<String> = []
                try await restore(group, known: &none)
            }
            for _ in 0..<((group.version == nil ? 0 : 1) + group.nodes.count) { step() }
        }
        var writes: [SpaceWrite] = []
        for version in found.versions {
            writes.append(
                .update(
                    collection: Lexicon.version, rkey: version.id, value: try stored(version.record, id: version.id)))
        }
        for node in found.nodes {
            writes.append(.update(collection: Lexicon.node, rkey: node.id, value: try stored(node.record, id: node.id)))
        }
        for part in found.parts {
            writes.append(
                .update(collection: Lexicon.chunks, rkey: part.key, value: try stored(part.chunks, key: part.key)))
        }
        for batch in transactions(writes) {
            do {
                try await apply(batch)
            } catch let error as XRPCError where Self.isRace(error) {
                // Something in it was deleted meanwhile (pruned, say): the rest, one by one.
                for write in batch {
                    do { try await apply([write]) } catch let error as XRPCError where Self.isRace(error) {}
                }
            }
            for _ in batch { step() }
        }
    }

    /// Downloads a chunk list's contents, stores them again the way the drive now does, and
    /// points the version that holds the list, and the nodes that share it, at the new chunks.
    ///
    /// A list long enough for `chunks` records gets new ones, numbered after the old: the version
    /// and node switch to them in one write, and only then are the old ones deleted, so the list
    /// is whole at every moment.
    private func restore(_ group: Survey.Contents, known: inout Set<String>) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("atdrive-convert-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        var hasher = SHA256()
        var size = 0
        do {
            try await readChunks(group.chunks, of: group.name, local: nil) { data in
                hasher.update(data: data)
                size += data.count
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if let expected = group.sha256, hasher.finalize().hexString != expected {
            throw ATDriveError.integrity("\(group.name) doesn't match its SHA-256")
        }
        let contents = try await store(file, known: known, progress: nil)
        known.formUnion(contents.uploaded)
        known.formUnion(contents.reused)

        let parts = Self.continuationParts(of: contents.chunks, limit: transfers.chunkListLimit)
        let old = group.version?.record
        let oldFirst = max(old?.continuationsFrom ?? 1, 1)
        let oldCount = old?.continuations ?? 0
        let first = oldFirst + oldCount
        if let version = group.version {
            for (index, part) in parts.enumerated() {
                let key = Lexicon.continuationKey(of: version.id, first + index)
                let value = try stored(part, key: key)
                do {
                    try await apply([.create(collection: Lexicon.chunks, rkey: key, value: value)])
                } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
                    try await apply([.update(collection: Lexicon.chunks, rkey: key, value: value)])  // an earlier try's
                }
            }
        } else if !parts.isEmpty {
            return  // a node alone can't hold a list this long: left as it is
        }
        var writes: [SpaceWrite] = []
        if let version = group.version {
            var record = version.record
            record.chunks = contents.chunks
            record.continuations = parts.isEmpty ? nil : parts.count
            record.continuationsFrom = parts.isEmpty || first == 1 ? nil : first
            writes.append(
                .update(collection: Lexicon.version, rkey: version.id, value: try stored(record, id: version.id)))
        }
        for node in group.nodes {
            var record = node.record
            record.chunks = contents.chunks
            record.continuations = parts.isEmpty ? nil : parts.count
            record.continuationsFrom = parts.isEmpty || first == 1 ? nil : first
            writes.append(.update(collection: Lexicon.node, rkey: node.id, value: try stored(record, id: node.id)))
        }
        do {
            try await apply(writes)
        } catch let error as XRPCError where Self.isRace(error) {
            // The version was pruned, or a node deleted, meanwhile: whichever are still there.
            for write in writes {
                do { try await apply([write]) } catch let error as XRPCError where Self.isRace(error) {}
            }
        }
        if let version = group.version, oldCount > 0 {
            let keys = (oldFirst..<first).map { Lexicon.continuationKey(of: version.id, $0) }
            _ = try await deleteRecords([keys.map { .delete(collection: Lexicon.chunks, rkey: $0) }])
        }
    }
}

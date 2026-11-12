import Crypto
import Foundation

/// Gets a drive's key onto this device, with a passkey.
///
/// Signing in to the PDS can't be what unlocks the drive: anything the PDS lets you fetch, its
/// operator can fetch too. So the drive key is kept on the PDS only wrapped by a key that comes
/// from a passkey (WebAuthn's PRF extension: the passkey turns a fixed input into 32 secret
/// bytes, the same every time, and only the passkey can do it). Passkeys sync between your
/// devices through iCloud Keychain, Google Password Manager, 1Password and so on, so unlocking a
/// new device is just a Touch ID or phone prompt during sign-in.
///
/// Native apps can't use a website's passkeys, so the passkey prompt happens on a small static
/// page (`web/unlock/`), opened in the browser right after the PDS's sign-in page. It hands the
/// PRF output back to the app the same way the sign-in page does, by redirecting to 127.0.0.1,
/// sealed to a one-time key the app made (`PasskeyRequest`), so it isn't readable in the
/// browser's history or a pasted address.
///
/// - **First sign-in** (`mode == .create`): the page creates a passkey, and this makes a random
///   drive key, wraps it for the passkey, and stores it in a `me.jsnelgro.atdrive.key` record.
/// - **Later sign-ins** (`.unlock`): the page asks for one of the drive's passkeys, and this
///   unwraps the drive key with it.
///
/// The PRF input is SHA-256("atdrive drive key v1\n" + DID), and the wrapping key is
/// HKDF-SHA256 of the PRF output (`PasskeyResult.wrappingKey`). Neither may ever change: they're
/// what turns a passkey into its drive's key.
public struct DriveUnlock: Sendable {
    public enum Mode: String, Sendable {
        case create, unlock
    }

    public let mode: Mode
    let client: XRPCClient
    let owner: String
    let space: String
    let keys: [KeyRecord]

    /// The record key of the first passkey's record. It's created with create-if-absent, so if
    /// two devices set up the same drive at once, only one key wins.
    static let firstKeyRecord = "first"

    /// The unlock page. Override with `ATDRIVE_UNLOCK_PAGE` (e.g. to test a local copy).
    public static func page(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configured = environment["ATDRIVE_UNLOCK_PAGE"], let url = URL(string: configured) { return url }
        return URL(string: "https://atdrive.jsnelgro.me/unlock/")!
    }

    /// Looks at the drive to see whether it needs setting up or unlocking.
    public static func prepare(client: XRPCClient, owner: String, driveKey: String = Lexicon.defaultDriveKey)
        async throws -> DriveUnlock
    {
        let space = XRPCClient.spaceURI(authority: owner, type: Lexicon.driveSpace, key: driveKey)
        let keys = try await listAll(KeyRecord.self, in: Lexicon.key, client: client, space: space, owner: owner)
            .filter { $0.kind == KeyRecord.passkey }
        if keys.isEmpty {
            // A drive with encrypted items but no key record lost it (or the server dropped it).
            // Making a new key wouldn't open those items, so don't.
            let nodes = try await listAll(StoredNode.self, in: Lexicon.node, client: client, space: space, owner: owner)
            if nodes.contains(where: { if case .sealed = $0 { true } else { false } }) {
                throw ATDriveError.encryption(
                    "your drive is encrypted, but the record holding its key is missing from your PDS")
            }
        }
        return DriveUnlock(
            mode: keys.isEmpty ? .create : .unlock, client: client, owner: owner, space: space, keys: keys)
    }

    /// The passkeys that can unlock the drive (credential IDs, base64url), for the page to ask for.
    public var credentialIDs: [String] { keys.map(\.credentialID) }

    /// Finishes with what the passkey produced: sets up the drive (`.create`) or unwraps its key.
    public func finish(with passkey: PasskeyResult) async throws -> DriveKey {
        switch mode {
        case .create:
            let driveKey = DriveKey.random()
            let record = KeyRecord(
                kind: KeyRecord.passkey, credentialID: passkey.credentialID, keyID: driveKey.id,
                wrapped: Sealed.seal(
                    driveKey.rawValue, key: passkey.wrappingKey, context: context(passkey.credentialID)))
            try await client.createDriveSpace(space)
            do {
                try await client.createSpaceRecord(
                    space: space, repo: owner, collection: Lexicon.key, rkey: Self.firstKeyRecord, record: record)
            } catch let error as XRPCError where error.error == "RecordAlreadyExists" {
                throw ATDriveError.encryption("another device set up your drive at the same moment; sign in again")
            }
            return driveKey
        case .unlock:
            guard let record = keys.first(where: { $0.credentialID == passkey.credentialID }) else {
                throw ATDriveError.encryption(
                    "that passkey can't unlock this drive; use the one you set ATDrive up with")
            }
            let raw: Data
            do {
                raw = try Sealed.open(record.wrapped, key: passkey.wrappingKey, context: context(record.credentialID))
            } catch {
                throw ATDriveError.encryption("that passkey couldn't unlock your drive (its key record was changed)")
            }
            let driveKey = try DriveKey(rawValue: raw)
            guard driveKey.id == record.keyID else {
                throw ATDriveError.encryption("your drive's key record doesn't match the key inside it")
            }
            return driveKey
        }
    }

    /// What a wrapped key is bound to: this drive and the passkey it's for.
    private func context(_ credentialID: String) -> String { "\(space)/\(Lexicon.key)/\(credentialID)" }

    private static func listAll<Value: Decodable & Sendable>(
        _: Value.Type, in collection: String, client: XRPCClient, space: String, owner: String
    ) async throws -> [Value] {
        var values: [Value] = []
        var cursor: String?
        repeat {
            let page: XRPCClient.SpaceRecordPage<Value>
            do {
                page = try await client.listSpaceRecords(
                    space: space, repo: owner, collection: collection, cursor: cursor, as: Value.self)
            } catch let error as XRPCError where error.error == "SpaceNotFound" || error.error == "RepoNotFound" {
                return []
            }
            values += page.records.compactMap(\.value)
            cursor = page.records.isEmpty ? nil : page.cursor
        } while cursor != nil
        return values
    }
}

/// What the unlock page sends back: which passkey was used, and its PRF output.
public struct PasskeyResult: Sendable {
    /// base64url.
    public var credentialID: String
    var prf: Data

    init(credentialID: String, prf: Data) {
        self.credentialID = credentialID
        self.prf = prf
    }

    /// The key that wraps the drive key for this passkey.
    var wrappingKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: prf), info: Data("atdrive passkey wrap v1".utf8),
            outputByteCount: 32)
    }
}

/// One trip to the unlock page. The page seals its result to this request's one-time P-256 key
/// (ECDH, HKDF-SHA256, AES-256-GCM, bound to `state`), so the result can travel through a URL.
///
/// The page's URL carries everything in its fragment (never sent to the page's server):
/// `v=1`, `mode`, `did`, `handle`, `pk` (this key), `state`, `return` (where to send the
/// result) and, to unlock, `creds` (the drive's passkeys). It redirects to
/// `<return>?state=…&result=…`, or `&error=…`.
public struct PasskeyRequest: Sendable {
    private let key: P256.KeyAgreement.PrivateKey
    public let state: String

    public init() {
        key = P256.KeyAgreement.PrivateKey()
        state = Base64URL.random(bytes: 16)
    }

    init(key: P256.KeyAgreement.PrivateKey, state: String) {
        self.key = key
        self.state = state
    }

    public func pageURL(page: URL, unlock: DriveUnlock, did: String, handle: String, returnTo: URL) -> URL {
        var fields = [
            ("v", "1"), ("mode", unlock.mode.rawValue), ("did", did), ("handle", handle),
            ("pk", Base64URL.encode(key.publicKey.x963Representation)), ("state", state),
            ("return", returnTo.absoluteString),
        ]
        if unlock.mode == .unlock { fields.append(("creds", unlock.credentialIDs.joined(separator: ","))) }
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        components.percentEncodedFragment = FormEncoding.encode(fields)
        return components.url!
    }

    /// Opens the page's sealed `result`.
    public func open(_ result: String) throws -> PasskeyResult {
        let failed = ATDriveError.loginFailed("the unlock page's answer couldn't be read; try again")
        guard let bytes = Base64URL.decode(result), bytes.count > 65 + 12 + 16 else { throw failed }
        let ephemeral = bytes.prefix(65)
        let box = bytes.dropFirst(65)
        struct Payload: Decodable {
            var credentialID: String
            var prf: String
        }
        do {
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephemeral)
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            let aesKey = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data(ephemeral) + key.publicKey.x963Representation,
                sharedInfo: Data("atdrive unlock v1".utf8), outputByteCount: 32)
            let plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: box), using: aesKey, authenticating: Data(state.utf8))
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard let prf = Base64URL.decode(payload.prf), prf.count == 32, !payload.credentialID.isEmpty else {
                throw failed
            }
            return PasskeyResult(credentialID: payload.credentialID, prf: prf)
        } catch {
            throw failed
        }
    }

    /// The page's answer, from what the user copied out of their browser
    /// (`http://127.0.0.1:53251/unlocked?state=…&result=…`, with or without the `http://`).
    public static func answer(fromPasted text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question = trimmed.firstIndex(of: "?"),
            let items = URLComponents(string: "http://127.0.0.1/" + trimmed[question...])?.queryItems
        else { return nil }
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard params["state"] != nil, params["result"] != nil || params["error"] != nil else { return nil }
        return params
    }

    /// The page's answer, from its query parameters: the result, or the error it reported.
    public func result(from params: [String: String]) throws -> PasskeyResult {
        guard params["state"] == state else { throw ATDriveError.loginFailed("that's from a different sign-in") }
        if let error = params["error"] { throw ATDriveError.loginFailed(error) }
        return try open(params["result"] ?? "")
    }
}

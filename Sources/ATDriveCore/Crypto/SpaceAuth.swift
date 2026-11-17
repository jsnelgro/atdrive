import Crypto
import Foundation

// What reading someone else's space takes, from the spaces proposal (0016, "Access control" and
// "Commit authenticity"): a request signature binding a space credential to a key, and MACs on
// the commits a repo host returns. Checked against the reference (`@atproto/space`'s
// `http-signature.ts`, `mac.ts` and `kem.ts`) and its vectors in `SpaceAuthTests`.

/// P-256 public keys as `did:key` and atproto multikeys: base58btc (`z…`) of the multicodec
/// `p256-pub` (0x1200, as the varint `80 24`) and the compressed point.
public enum P256DIDKey {
    static let prefix: [UInt8] = [0x80, 0x24]

    /// `z…` multibase, as in a DID document's `publicKeyMultibase`.
    public static func multikey(_ key: P256.KeyAgreement.PublicKey) -> String {
        "z" + Base58.encode(prefix + key.compressedRepresentation)
    }

    public static func didKey(_ key: P256.KeyAgreement.PublicKey) -> String { "did:key:" + multikey(key) }
    public static func didKey(_ key: P256.Signing.PublicKey) -> String {
        "did:key:z" + Base58.encode(prefix + key.compressedRepresentation)
    }

    /// The key a `did:key:z…` or a `z…` multikey holds; `nil` if it isn't a P-256 one.
    public static func publicKey(_ text: String) -> P256.KeyAgreement.PublicKey? {
        var text = Substring(text)
        if text.hasPrefix("did:key:") { text = text.dropFirst(8) }
        guard text.first == "z", let bytes = Base58.decode(String(text.dropFirst())), bytes.count == 35,
            Array(bytes.prefix(2)) == prefix
        else { return nil }
        return try? P256.KeyAgreement.PublicKey(compressedRepresentation: bytes.dropFirst(2))
    }
}

/// Bitcoin-alphabet base58, as multibase `z` uses.
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    static func encode<S: Sequence<UInt8>>(_ input: S) -> String {
        let bytes = Array(input)
        var digits: [UInt8] = []  // base 58, least significant first
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let zeros = bytes.prefix { $0 == 0 }.count
        return String(repeating: "1", count: zeros)
            + String(decoding: digits.reversed().map { alphabet[Int($0)] }, as: UTF8.self)
    }

    static func decode(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []  // base 256, least significant first
        for character in text.utf8 {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            var carry = value
            for index in bytes.indices {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        let zeros = text.utf8.prefix { $0 == UInt8(ascii: "1") }.count
        return [UInt8](repeating: 0, count: zeros) + bytes.reversed()
    }
}

/// The parts of RFC 8941 structured fields that space headers use: dictionaries whose members are
/// bare items (integers, strings, tokens, booleans, byte sequences) or inner lists of them, with
/// parameters. Enough to read and canonically re-serialize `Atproto-Space-Commit`,
/// `Signature-Input` and `Signature`.
enum StructuredField {
    enum Item: Equatable {
        case integer(Int)
        case string(String)
        case token(String)
        case boolean(Bool)
        case bytes(Data)
    }

    struct Member: Equatable {
        /// One item, or an inner list of them (`items` with `isList`).
        var items: [(Item, [(String, Item)])]
        var isList: Bool
        var parameters: [(String, Item)]

        static func == (a: Member, b: Member) -> Bool {
            StructuredField.serialize(a) == StructuredField.serialize(b)
        }

        var item: Item? { isList ? nil : items.first?.0 }
    }

    typealias Dictionary = [(key: String, member: Member)]

    static func serialize(_ item: Item) -> String {
        switch item {
        case .integer(let value): String(value)
        case .string(let value):
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                + "\""
        case .token(let value): value
        case .boolean(let value): value ? "?1" : "?0"
        case .bytes(let value): ":" + value.base64EncodedString() + ":"
        }
    }

    static func serialize(_ parameters: [(String, Item)]) -> String {
        parameters.map { key, value in
            if case .boolean(true) = value { return ";" + key }
            return ";" + key + "=" + serialize(value)
        }.joined()
    }

    static func serialize(_ member: Member) -> String {
        let items = member.items.map { serialize($0.0) + serialize($0.1) }
        let body = member.isList ? "(" + items.joined(separator: " ") + ")" : items.first ?? ""
        return body + serialize(member.parameters)
    }

    static func serialize(_ dictionary: Dictionary) -> String {
        dictionary.map { key, member in
            if !member.isList, case .boolean(true)? = member.item { return key + serialize(member.parameters) }
            return key + "=" + serialize(member)
        }.joined(separator: ", ")
    }

    /// Parses a dictionary; `nil` if it isn't one this understands.
    static func parseDictionary(_ text: String) -> Dictionary? {
        var parser = Parser(Array(text.utf8))
        return parser.dictionary()
    }

    private struct Parser {
        var input: [UInt8]
        var position = 0

        init(_ input: [UInt8]) { self.input = input }

        var current: UInt8? { position < input.count ? input[position] : nil }

        mutating func skipSpaces() {
            while let byte = current, byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") { position += 1 }
        }

        mutating func dictionary() -> Dictionary? {
            var result: Dictionary = []
            skipSpaces()
            while current != nil {
                guard let key = key() else { return nil }
                var member = Member(items: [(.boolean(true), [])], isList: false, parameters: [])
                if current == UInt8(ascii: "=") {
                    position += 1
                    guard let parsed = memberValue() else { return nil }
                    member = parsed
                } else {
                    guard let parameters = parameters() else { return nil }
                    member.parameters = parameters
                }
                result.removeAll { $0.key == key }
                result.append((key, member))
                skipSpaces()
                if current == nil { break }
                guard current == UInt8(ascii: ",") else { return nil }
                position += 1
                skipSpaces()
                if current == nil { return nil }
            }
            return result
        }

        mutating func memberValue() -> Member? {
            if current == UInt8(ascii: "(") {
                position += 1
                var items: [(Item, [(String, Item)])] = []
                while true {
                    skipSpaces()
                    if current == UInt8(ascii: ")") {
                        position += 1
                        break
                    }
                    guard let item = bareItem(), let parameters = parameters() else { return nil }
                    items.append((item, parameters))
                    guard let byte = current, byte == UInt8(ascii: " ") || byte == UInt8(ascii: ")") else { return nil }
                }
                guard let parameters = parameters() else { return nil }
                return Member(items: items, isList: true, parameters: parameters)
            }
            guard let item = bareItem(), let parameters = parameters() else { return nil }
            return Member(items: [(item, [])], isList: false, parameters: parameters)
        }

        mutating func parameters() -> [(String, Item)]? {
            var result: [(String, Item)] = []
            while current == UInt8(ascii: ";") {
                position += 1
                skipSpaces()
                guard let key = key() else { return nil }
                var value = Item.boolean(true)
                if current == UInt8(ascii: "=") {
                    position += 1
                    guard let item = bareItem() else { return nil }
                    value = item
                }
                result.removeAll { $0.0 == key }
                result.append((key, value))
            }
            return result
        }

        mutating func key() -> String? {
            guard let first = current, (first >= 0x61 && first <= 0x7A) || first == UInt8(ascii: "*") else { return nil }
            let start = position
            while let byte = current,
                (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || "_-.*".utf8.contains(byte)
            {
                position += 1
            }
            return String(decoding: input[start..<position], as: UTF8.self)
        }

        mutating func bareItem() -> Item? {
            guard let first = current else { return nil }
            switch first {
            case UInt8(ascii: "\""):
                position += 1
                var bytes: [UInt8] = []
                while let byte = current {
                    position += 1
                    if byte == UInt8(ascii: "\\") {
                        guard let next = current, next == UInt8(ascii: "\"") || next == UInt8(ascii: "\\") else {
                            return nil
                        }
                        bytes.append(next)
                        position += 1
                    } else if byte == UInt8(ascii: "\"") {
                        return .string(String(decoding: bytes, as: UTF8.self))
                    } else {
                        guard byte >= 0x20, byte < 0x7F else { return nil }
                        bytes.append(byte)
                    }
                }
                return nil
            case UInt8(ascii: ":"):
                position += 1
                let start = position
                while let byte = current, byte != UInt8(ascii: ":") { position += 1 }
                guard current == UInt8(ascii: ":"),
                    let data = Data(base64Encoded: String(decoding: input[start..<position], as: UTF8.self))
                else { return nil }
                position += 1
                return .bytes(data)
            case UInt8(ascii: "?"):
                position += 1
                defer { position += 1 }
                switch current {
                case UInt8(ascii: "1"): return .boolean(true)
                case UInt8(ascii: "0"): return .boolean(false)
                default: return nil
                }
            case UInt8(ascii: "-"), 0x30...0x39:
                let start = position
                position += 1
                while let byte = current, byte >= 0x30, byte <= 0x39 { position += 1 }
                return Int(String(decoding: input[start..<position], as: UTF8.self)).map(Item.integer)
            default:
                guard (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) || first == UInt8(ascii: "*")
                else { return nil }
                let start = position
                while let byte = current, byte > 0x20, byte < 0x7F, !"\"(),;=[]{}\\ ".utf8.contains(byte) {
                    position += 1
                }
                return .token(String(decoding: input[start..<position], as: UTF8.self))
            }
        }
    }
}

/// The RFC 9421 signature base for a signature covering `components` (already serialized, e.g.
/// `"authorization"`), whose values are given in order, under `signatureParams`.
func signatureBase(components: [String], values: [String], signatureParams: String) -> Data {
    var lines = zip(components, values).map { "\($0): \($1.trimmingCharacters(in: .whitespaces))" }
    lines.append("\"@signature-params\": \(signatureParams)")
    return Data(lines.joined(separator: "\n").utf8)
}

/// Signs requests made with a space credential: an HTTP message signature (RFC 9421, ECDSA P-256)
/// over the `Authorization` header and the audience (the DID whose repo is read), with the key the
/// credential is bound to.
public struct SpaceRequestSigner: Sendable {
    let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    /// What `authorizeSpaceSync` binds the credential to.
    public var didKey: String { P256DIDKey.didKey(key.publicKey) }

    static let tag = "atproto-space-credential"
    static let components = ["\"authorization\"", "\"atproto-space-audience\""]
    static let signatureParams = "(\(components.joined(separator: " ")));tag=\"\(tag)\""

    /// The headers for one request: `Authorization`, `Atproto-Space-Audience`, `Signature-Input`
    /// and `Signature`.
    public func headers(credential: String, audience: String) throws -> [String: String] {
        let authorization = "Atproto-Space-Credential \(credential)"
        let base = signatureBase(
            components: Self.components, values: [authorization, audience], signatureParams: Self.signatureParams)
        let signature = try key.signature(for: base).rawRepresentation
        return [
            "Authorization": authorization,
            "Atproto-Space-Audience": audience,
            "Signature-Input": "sig=\(Self.signatureParams)",
            "Signature": "sig=:\(signature.base64EncodedString()):",
        ]
    }

    /// Whether a request carries a valid signature by `key` (for tests, and the fake PDS).
    static func verify(_ headers: [String: String], key: P256.Signing.PublicKey) -> Bool {
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
        guard let authorization = header("Authorization"), let audience = header("Atproto-Space-Audience"),
            let input = header("Signature-Input").flatMap(StructuredField.parseDictionary),
            let signatures = header("Signature").flatMap(StructuredField.parseDictionary),
            let tagged = input.first(where: { $0.member.parameters.contains { $0.0 == "tag" && $0.1 == .string(tag) } }),
            case .bytes(let raw)? = signatures.first(where: { $0.key == tagged.key })?.member.item,
            let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
        else { return false }
        let params = StructuredField.serialize(tagged.member)
        guard params == signatureParams else { return false }
        let base = signatureBase(components: components, values: [authorization, audience], signatureParams: params)
        return key.isValidSignature(signature, for: base)
    }
}

/// MACs on commits from a repo host (0016, "Commit authenticity"). The reader derives a fresh
/// secret with the repo owner's KEM key (`#atproto_kem` in its DID document, P-256) by HPKE secret
/// export, sends its ephemeral key with the request, and checks the HMAC the host returns over an
/// `Atproto-Space-Commit` header against the commit in the body. A host that can't derive the same
/// secret (one that isn't the owner's) can't make one that passes.
public enum SpaceMAC {
    static let commitProfile = "atproto-space-commit"
    static let commitHeader = "Atproto-Space-Commit"
    static let components = ["\"\(commitProfile)\";sf"]

    /// A request's half: its `Accept-Signature` header, and the secret to check the answer with.
    public struct Request: Sendable {
        public let keyShare: String
        let secret: SymmetricKey

        public var acceptSignature: String { "mac=\(signatureParams)" }
        var signatureParams: String {
            "(\(SpaceMAC.components[0]));keyid=\"\(keyShare)\";tag=\"\(SpaceMAC.commitProfile)\""
        }
    }

    /// A fresh secret shared with whoever holds the private half of `kemKey`.
    public static func request(kemKey: P256.KeyAgreement.PublicKey) throws -> Request {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let dh = try ephemeral.sharedSecretFromKeyAgreement(with: kemKey)
        let secret = exportedSecret(
            dh: dh.withUnsafeBytes { Data($0) }, enc: ephemeral.publicKey.x963Representation,
            recipient: kemKey.x963Representation)
        return Request(keyShare: P256DIDKey.didKey(ephemeral.publicKey), secret: secret)
    }

    /// The host's half: the secret for a request's key share (`did:key`), with the owner's KEM key.
    static func secret(keyShare: String, kemKey: P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        guard let share = P256DIDKey.publicKey(keyShare) else { throw SpaceAuthError.mac("malformed keyid") }
        let dh = try kemKey.sharedSecretFromKeyAgreement(with: share)
        return exportedSecret(
            dh: dh.withUnsafeBytes { Data($0) }, enc: share.x963Representation,
            recipient: kemKey.publicKey.x963Representation)
    }

    /// HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, export-only, `info`
    /// "atproto-mac", empty exporter context, 32 bytes: written out as the proposal's appendix does.
    static func exportedSecret(dh: Data, enc: Data, recipient: Data) -> SymmetricKey {
        func uint16(_ value: Int) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
        let kemID = Data("KEM".utf8) + uint16(0x0010)
        let suiteID = Data("HPKE".utf8) + uint16(0x0010) + uint16(0x0001) + uint16(0xFFFF)
        func extract(_ id: Data, salt: Data, _ label: String, _ ikm: Data) -> Data {
            Data(
                HKDF<SHA256>.extract(
                    inputKeyMaterial: SymmetricKey(data: Data("HPKE-v1".utf8) + id + Data(label.utf8) + ikm),
                    salt: salt))
        }
        func expand(_ id: Data, _ prk: Data, _ label: String, _ info: Data, _ length: Int) -> Data {
            HKDF<SHA256>.expand(
                pseudoRandomKey: SymmetricKey(data: prk),
                info: uint16(length) + Data("HPKE-v1".utf8) + id + Data(label.utf8) + info, outputByteCount: length
            ).withUnsafeBytes { Data($0) }
        }
        let eaePRK = extract(kemID, salt: Data(), "eae_prk", dh)
        let kemSecret = expand(kemID, eaePRK, "shared_secret", enc + recipient, 32)
        let context =
            Data([0]) + extract(suiteID, salt: Data(), "psk_id_hash", Data())
            + extract(suiteID, salt: Data(), "info_hash", Data("atproto-mac".utf8))
        let secret = extract(suiteID, salt: kemSecret, "secret", Data())
        let exporterSecret = expand(suiteID, secret, "exp", context, 32)
        return SymmetricKey(data: expand(suiteID, exporterSecret, "sec", Data(), 32))
    }

    /// The `Atproto-Space-Commit` header describing a commit.
    static func commitHeader(_ commit: RepoCommit) -> String {
        StructuredField.serialize([
            ("ver", .init(items: [(.integer(commit.ver ?? 1), [])], isList: false, parameters: [])),
            ("repo", .init(items: [(.string(commit.repo ?? ""), [])], isList: false, parameters: [])),
            ("space", .init(items: [(.string(commit.space ?? ""), [])], isList: false, parameters: [])),
            ("rev", .init(items: [(.string(commit.rev), [])], isList: false, parameters: [])),
            ("data", .init(items: [(.bytes(commit.data), [])], isList: false, parameters: [])),
        ])
    }

    /// The host's response headers for `commit`, answering `acceptSignature` (for the fake PDS).
    static func responseHeaders(for commit: RepoCommit, acceptSignature: String, kemKey: P256.KeyAgreement.PrivateKey)
        throws -> [String: String]
    {
        guard let requests = StructuredField.parseDictionary(acceptSignature),
            let request = requests.first(where: {
                $0.member.parameters.contains { $0.0 == "tag" && $0.1 == .string(commitProfile) }
            }),
            case .string(let keyShare)? = request.member.parameters.first(where: { $0.0 == "keyid" })?.1
        else { throw SpaceAuthError.mac("malformed Accept-Signature") }
        let secret = try secret(keyShare: keyShare, kemKey: kemKey)
        let params = StructuredField.serialize(request.member)
        let header = commitHeader(commit)
        let base = signatureBase(components: components, values: [header], signatureParams: params)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: base, using: secret))
        return [
            commitHeader: header, "Signature-Input": "\(request.key)=\(params)",
            "Signature": "\(request.key)=:\(mac.base64EncodedString()):",
        ]
    }

    /// Checks a response's MAC, and that the header it covers describes `commit`: the one in the
    /// body, for the repo and space asked about.
    static func verify(
        _ commit: RepoCommit, headers: (String) -> String?, request: Request, repo: String, space: String
    ) throws {
        guard let input = headers("Signature-Input").flatMap(StructuredField.parseDictionary),
            let signatures = headers("Signature").flatMap(StructuredField.parseDictionary)
        else { throw SpaceAuthError.mac("the response has no MAC") }
        let tagged = input.filter { $0.member.parameters.contains { $0.0 == "tag" && $0.1 == .string(commitProfile) } }
        guard tagged.count == 1, let member = tagged.first,
            case .bytes(let mac)? = signatures.first(where: { $0.key == member.key })?.member.item
        else { throw SpaceAuthError.mac("the response has no MAC") }
        guard member.member.isList, member.member.items.count == 1,
            StructuredField.serialize(member.member.items[0].0) + StructuredField.serialize(member.member.items[0].1)
                == components[0],
            member.member.parameters.allSatisfy({ name, value in
                switch name {
                case "keyid": value == .string(request.keyShare)
                case "alg": value == .string("hmac-sha256")
                default: true
                }
            })
        else { throw SpaceAuthError.mac("the MAC isn't the one asked for") }
        guard let header = headers(commitHeader), let fields = StructuredField.parseDictionary(header) else {
            throw SpaceAuthError.mac("the response has no \(commitHeader) header")
        }
        let base = signatureBase(
            components: components, values: [StructuredField.serialize(fields)],
            signatureParams: StructuredField.serialize(member.member))
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: base, using: request.secret) else {
            throw SpaceAuthError.mac("the commit's MAC doesn't match: it didn't come from the repo's host")
        }
        func field(_ key: String) -> StructuredField.Item? { fields.first { $0.key == key }?.member.item }
        guard field("ver") == .integer(commit.ver ?? 1), field("repo") == .string(repo),
            field("space") == .string(space), field("rev") == .string(commit.rev), field("data") == .bytes(commit.data),
            commit.repo.map({ $0 == repo }) ?? true, commit.space.map({ $0 == space }) ?? true
        else { throw SpaceAuthError.mac("the commit doesn't match its MAC") }
    }
}

public enum SpaceAuthError: Error, Equatable, CustomStringConvertible {
    case mac(String)
    case noKEMKey(String)

    public var description: String {
        switch self {
        case .mac(let reason): "couldn't verify the space's commit: \(reason)"
        case .noKEMKey(let did): "\(did) publishes no key to verify its space commits with (#atproto_kem)"
        }
    }
}

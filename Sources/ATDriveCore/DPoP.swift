import Crypto
import Foundation

/// The key an OAuth session's tokens are bound to (DPoP, RFC 9449). Every request carries a
/// short-lived proof signed with it, so a leaked token is useless without the key.
public struct DPoPKey: Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public init() {
        privateKey = P256.Signing.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    var publicJWK: [String: String] {
        let point = privateKey.publicKey.x963Representation  // 0x04 ‖ x ‖ y
        return [
            "kty": "EC", "crv": "P-256",
            "x": Base64URL.encode(point.dropFirst().prefix(32)),
            "y": Base64URL.encode(point.suffix(32)),
        ]
    }

    /// A proof for one HTTP request. `accessToken` is set when calling a resource (the PDS),
    /// and left out when talking to the authorization server.
    func proof(method: String, url: URL, nonce: String?, accessToken: String? = nil) throws -> String {
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        target.query = nil
        target.fragment = nil
        var claims: [String: Any] = [
            "jti": UUID().uuidString,
            "htm": method,
            "htu": target.url!.absoluteString,
            "iat": Int(Date().timeIntervalSince1970),
        ]
        if let nonce { claims["nonce"] = nonce }
        if let accessToken { claims["ath"] = Base64URL.encode(SHA256.hash(data: Data(accessToken.utf8))) }
        let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": publicJWK]

        let signingInput = try "\(Base64URL.encode(json(header))).\(Base64URL.encode(json(claims)))"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(Base64URL.encode(signature.rawRepresentation))"
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum Base64URL {
    static func encode<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// Random bytes, encoded: for PKCE verifiers and `state`.
    static func random(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return encode((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

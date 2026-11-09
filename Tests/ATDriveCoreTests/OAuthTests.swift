import Crypto
import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite struct OAuthTests {
    @Test func dpopProofIsAValidSignedJWT() throws {
        let key = DPoPKey()
        let url = URL(string: "https://pds.test/xrpc/com.atproto.space.listRecords?space=x&repo=y")!
        let proof = try key.proof(method: "GET", url: url, nonce: "n1", accessToken: "token")
        let parts = proof.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try JSONSerialization.jsonObject(with: Base64URL.decode(parts[0])!) as! [String: Any]
        let claims = try JSONSerialization.jsonObject(with: Base64URL.decode(parts[1])!) as! [String: Any]
        #expect(header["typ"] as? String == "dpop+jwt")
        #expect(header["alg"] as? String == "ES256")
        #expect(claims["htm"] as? String == "GET")
        #expect(claims["htu"] as? String == "https://pds.test/xrpc/com.atproto.space.listRecords")  // no query
        #expect(claims["nonce"] as? String == "n1")
        #expect(claims["ath"] as? String == Base64URL.encode(SHA256.hash(data: Data("token".utf8))))

        // The signature verifies against the public key embedded in the header.
        let jwk = header["jwk"] as! [String: String]
        let point = Data([0x04]) + Base64URL.decode(jwk["x"]!)! + Base64URL.decode(jwk["y"]!)!
        let publicKey = try P256.Signing.PublicKey(x963Representation: point)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64URL.decode(parts[2])!)
        #expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))

        // And the key survives being saved and loaded.
        #expect(try DPoPKey(rawRepresentation: key.rawRepresentation).publicJWK == key.publicJWK)
    }

    @Test func loopbackClientIDCarriesTheScope() {
        let id = OAuthLogin.clientID(environment: [:])
        #expect(id.hasPrefix("http://localhost?scope=atproto%20space%3A%2A%3Fcollection%3Dme.jsnelgro.atdrive.node"))
        #expect(
            OAuthLogin.clientID(environment: ["ATDRIVE_OAUTH_CLIENT_ID": "https://x.test/c.json"])
                == "https://x.test/c.json")
        #expect(FormEncoding.encode([("a b", "c&d=é")]) == "a%20b=c%26d%3D%C3%A9")
    }

    @Test func loopbackServerCatchesTheRedirect() async throws {
        let server = try LoopbackServer()
        #expect(server.port > 0)
        async let params = server.waitForRedirect(timeout: 10)
        // A stray favicon request first, then the real redirect.
        _ = try? await URLSessionTransport().send(
            URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/favicon.ico")!))
        let (body, response) = try await URLSessionTransport().send(
            URLRequest(
                url: URL(string: "http://127.0.0.1:\(server.port)/?state=s1&code=c1&iss=https%3A%2F%2Fpds.test")!))
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("signed in"))
        #expect(try await params == ["state": "s1", "code": "c1", "iss": "https://pds.test"])
    }

    @Test func readsAPastedRedirectAddress() throws {
        let expected = ["iss": "https://pds.test", "state": "s1", "code": "c1"]
        let pasted = "http://127.0.0.1:53251/?iss=https%3A%2F%2Fpds.test&state=s1&code=c1"
        #expect(try OAuthLogin.redirectParameters(fromPasted: pasted) == expected)
        #expect(
            try OAuthLogin.redirectParameters(
                fromPasted: "  127.0.0.1:53251/?iss=https%3A%2F%2Fpds.test&state=s1&code=c1\n") == expected)
        #expect(
            try OAuthLogin.redirectParameters(fromPasted: "http://127.0.0.1:1/?state=s&error=access_denied")["error"]
                == "access_denied")
        for junk in ["", "hello", "https://example.com/", "http://127.0.0.1:1/?code=c1", "http://127.0.0.1:1/?state=s"]
        {
            #expect(throws: ATDriveError.self) { try OAuthLogin.redirectParameters(fromPasted: junk) }
        }
    }

    @Test func signInWithAPastedAddress() async throws {
        let server = FakeAuthorizationServer()
        let resolver = IdentityResolver(environment: ["ATDRIVE_PLC_URL": "https://plc.test"], transport: server)
        // As on a remote machine: the browser never reaches our listener; the user pastes instead.
        let session = try await OAuthLogin.signIn(
            identifier: "did:plc:alice", resolver: resolver, environment: [:], transport: server, timeout: 30,
            open: { _ in },
            pastedRedirect: {
                "http://127.0.0.1:9/?iss=https%3A%2F%2Fpds.test&state=\(server.lastPAR["state"]!)&code=the-code"
            })
        #expect(session.did == "did:plc:alice")
        #expect(session.accessJwt == "access-1")
    }

    @Test func fullSignInAgainstAFakeServer() async throws {
        let server = FakeAuthorizationServer()
        let resolver = IdentityResolver(environment: ["ATDRIVE_PLC_URL": "https://plc.test"], transport: server)
        let pending = try await OAuthLogin.prepare(
            identifier: "did:plc:alice", redirectURI: "http://127.0.0.1:5555/", resolver: resolver,
            environment: [:], transport: server)

        #expect(pending.authorizationURL.absoluteString.hasPrefix("https://pds.test/oauth/authorize?client_id="))
        #expect(server.parRequests == 2)  // first one asked for a DPoP nonce
        let par = server.lastPAR
        #expect(par["redirect_uri"] == "http://127.0.0.1:5555/")
        #expect(par["scope"] == OAuthLogin.scope(environment: [:]))
        #expect(par["code_challenge_method"] == "S256")

        // A response for someone else's request is rejected.
        await #expect(throws: ATDriveError.self) {
            _ = try await pending.complete(with: ["state": "forged", "code": "c"], transport: server)
        }
        let session = try await pending.complete(
            with: ["state": par["state"]!, "code": "the-code", "iss": "https://pds.test"], transport: server)
        #expect(session.did == "did:plc:alice")
        #expect(session.handle == "alice.test")
        #expect(session.accessJwt == "access-1")
        #expect(session.oauth?.clientID.hasPrefix("http://localhost?scope=") == true)
        // PKCE: the verifier sent at the end matches the challenge sent at the start.
        let verifier = try #require(server.lastToken["code_verifier"])
        #expect(Base64URL.encode(SHA256.hash(data: Data(verifier.utf8))) == par["code_challenge"])

        // Requests to the PDS use DPoP, and an expired token is refreshed transparently.
        let manager = SessionManager(session, transport: server)
        let client = XRPCClient(service: session.service, session: manager, transport: server)
        struct Output: Decodable { var ok: Bool }
        server.expireNextResourceRequest = true
        #expect(try await client.query("com.example.ping", as: Output.self).ok)
        #expect(await manager.session.accessJwt == "access-2")
        #expect(server.resourceAuthorizations.last == "DPoP access-2")
    }
}

/// Plays a PDS that is also its own authorization server, enough to drive the sign-in flow.
final class FakeAuthorizationServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var parRequests = 0
    private(set) var lastPAR: [String: String] = [:]
    private(set) var lastToken: [String: String] = [:]
    private(set) var resourceAuthorizations: [String] = []
    var expireNextResourceRequest = false
    private var issued = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { handle(request) }
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let form = Dictionary(
            (URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch (url.host ?? "", url.path) {
        case ("plc.test", "/did:plc:alice"):
            return json([
                "id": "did:plc:alice", "alsoKnownAs": ["at://alice.test"],
                "service": [
                    ["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.test"]
                ],
            ])
        case (_, "/.well-known/oauth-protected-resource"):
            return json(["resource": "https://pds.test", "authorization_servers": ["https://pds.test"]])
        case (_, "/.well-known/oauth-authorization-server"):
            return json([
                "issuer": "https://pds.test",
                "pushed_authorization_request_endpoint": "https://pds.test/oauth/par",
                "authorization_endpoint": "https://pds.test/oauth/authorize",
                "token_endpoint": "https://pds.test/oauth/token",
                "revocation_endpoint": "https://pds.test/oauth/revoke",
            ])
        case (_, "/oauth/par"):
            parRequests += 1
            if !proofHasNonce(request) { return json(["error": "use_dpop_nonce"], status: 400, nonce: "as-nonce") }
            lastPAR = form
            return json(["request_uri": "urn:ietf:params:oauth:request_uri:abc", "expires_in": 300], status: 201)
        case (_, "/oauth/token"):
            guard proofHasNonce(request) else {
                return json(["error": "use_dpop_nonce"], status: 400, nonce: "as-nonce")
            }
            if form["grant_type"] == "authorization_code" {
                guard form["code"] == "the-code" else { return json(["error": "invalid_grant"], status: 400) }
                lastToken = form
            }
            issued += 1
            return json([
                "access_token": "access-\(issued)", "token_type": "DPoP", "refresh_token": "refresh-\(issued)",
                "expires_in": 3600, "sub": "did:plc:alice", "scope": OAuthLogin.scope(environment: [:]),
            ])
        case (_, "/xrpc/com.example.ping"):
            resourceAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            guard request.value(forHTTPHeaderField: "DPoP") != nil else { return json(["error": "nope"], status: 401) }
            if expireNextResourceRequest {
                expireNextResourceRequest = false
                return json(["error": "invalid_token", "message": "expired"], status: 401)
            }
            return json(["ok": true])
        default:
            return json(["error": "NotFound"], status: 404)
        }
    }

    private func proofHasNonce(_ request: URLRequest) -> Bool {
        guard let proof = request.value(forHTTPHeaderField: "DPoP"),
            let payload = Base64URL.decode(String(proof.split(separator: ".")[1])),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return false }
        return claims["nonce"] as? String == "as-nonce"
    }

    private func json(_ object: Any, status: Int = 200, nonce: String? = nil) -> (Data, HTTPURLResponse) {
        var headers = ["Content-Type": "application/json"]
        if let nonce { headers["DPoP-Nonce"] = nonce }
        return (
            try! JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(
                url: URL(string: "https://pds.test")!, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }
}

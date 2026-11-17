import Foundation
import Testing

@testable import ATDriveCore

@Suite struct XRPCTests {
    let session = Session(
        did: "did:plc:test", handle: "alice.test", service: URL(string: "https://pds.test")!,
        accessJwt: "old-access", refreshJwt: "old-refresh",
        oauth: OAuthInfo(
            issuer: "https://auth.test", tokenEndpoint: URL(string: "https://auth.test/token")!,
            revocationEndpoint: nil, clientID: "http://localhost", dpopKey: DPoPKey().rawRepresentation,
            expiresAt: nil))

    final class Saved: @unchecked Sendable {
        var sessions: [Session] = []
    }

    @Test func refreshesExpiredTokenOnceAndRetries() async throws {
        let transport = ScriptedTransport([
            (401, #"{"error":"invalid_token","message":"Token has expired"}"#, [:]),
            (
                200,
                #"{"access_token":"new-access","token_type":"DPoP","refresh_token":"new-refresh","sub":"did:plc:test"}"#,
                [:]
            ),
            (200, #"{"value":42}"#, [:]),
        ])
        let saved = Saved()
        let manager = SessionManager(session, transport: transport) { saved.sessions.append($0) }
        let client = XRPCClient(service: session.service, session: manager, transport: transport)

        struct Output: Decodable { var value: Int }
        let output = try await client.query("com.example.thing", as: Output.self)

        #expect(output.value == 42)
        let auth = transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["DPoP old-access", nil, "DPoP new-access"])
        #expect(transport.requests[1].url == session.oauth.tokenEndpoint)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "DPoP") != nil })
        #expect(saved.sessions.map(\.refreshJwt) == ["new-refresh"])
        #expect(await manager.session.accessJwt == "new-access")
    }

    @Test func saysSoWhenTheSessionCantBeRenewed() async throws {
        // E.g. it was signed out elsewhere: the access token expires and refreshing is refused.
        let transport = ScriptedTransport([
            (401, #"{"error":"invalid_token","message":"Token has expired"}"#, [:]),
            (400, #"{"error":"invalid_grant","error_description":"Token has been revoked"}"#, [:]),
        ])
        let client = XRPCClient(
            service: session.service, session: SessionManager(session, transport: transport), transport: transport)
        await #expect(throws: ATDriveError.sessionEnded) {
            let _: XRPCClient.Empty = try await client.query("com.example.anything")
        }
    }

    @Test func surfacesServerErrors() async throws {
        let transport = ScriptedTransport([(400, #"{"error":"SpaceNotFound","message":"Space not found"}"#, [:])])
        let client = XRPCClient(service: session.service, session: SessionManager(session), transport: transport)
        do {
            let _: XRPCClient.Empty = try await client.procedure("com.atproto.space.putRecord", ["a": "b"])
            Issue.record("expected an error")
        } catch let error as XRPCError {
            #expect(error.error == "SpaceNotFound")
            #expect(error.status == 400)
            #expect(error.description == "SpaceNotFound: Space not found (HTTP 400 from com.atproto.space.putRecord)")
        }
    }

    @Test func waitsOutRateLimits() async throws {
        let reset = String(Int(Date().timeIntervalSince1970))  // already passed → minimum wait
        let transport = ScriptedTransport([
            (429, #"{"error":"RateLimitExceeded"}"#, ["ratelimit-reset": reset]),
            (200, "{}", [:]),
        ])
        let client = XRPCClient(service: session.service, transport: transport)
        let _: XRPCClient.Empty = try await client.procedure("com.example.write", ["a": "b"])
        #expect(transport.requests.count == 2)
    }

    @Test func resolvesDIDDocumentsPDS() throws {
        let json = #"""
            {"id":"did:plc:abc","alsoKnownAs":["at://alice.test"],
             "service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example"},
                        {"id":"#other","type":"Thing","serviceEndpoint":{"complex":true}}]}
            """#
        let document = try JSONDecoder().decode(DIDDocument.self, from: Data(json.utf8))
        #expect(document.pdsEndpoint == URL(string: "https://pds.example"))
    }
}

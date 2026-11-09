import Foundation
import Testing

@testable import ATDriveCore

@Suite struct XRPCTests {
    let session = Session(
        did: "did:plc:test", handle: "alice.test", service: URL(string: "https://pds.test")!,
        accessJwt: "old-access", refreshJwt: "old-refresh")

    final class Saved: @unchecked Sendable {
        var sessions: [Session] = []
    }

    @Test func refreshesExpiredTokenOnceAndRetries() async throws {
        let transport = ScriptedTransport([
            (400, #"{"error":"ExpiredToken","message":"Token has expired"}"#, [:]),
            (
                200,
                #"{"did":"did:plc:test","handle":"alice.test","accessJwt":"new-access","refreshJwt":"new-refresh"}"#,
                [:]
            ),
            (200, #"{"value":42}"#, [:]),
        ])
        let saved = Saved()
        let manager = SessionManager(session) { saved.sessions.append($0) }
        let client = XRPCClient(service: session.service, session: manager, transport: transport)

        struct Output: Decodable { var value: Int }
        let output = try await client.query("com.example.thing", as: Output.self)

        #expect(output.value == 42)
        let auth = transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["Bearer old-access", "Bearer old-refresh", "Bearer new-access"])
        #expect(transport.requests[1].url?.lastPathComponent == "com.atproto.server.refreshSession")
        #expect(saved.sessions.map(\.refreshJwt) == ["new-refresh"])
        #expect(await manager.session.accessJwt == "new-access")
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

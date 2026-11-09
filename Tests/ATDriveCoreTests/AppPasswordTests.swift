import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite struct AppPasswordTests {
    let account = Session(
        did: "did:plc:alice", handle: "alice.test", service: URL(string: "https://pds.test")!,
        accessJwt: "oauth-access", refreshJwt: "oauth-refresh")

    @Test func listCreateRevokeAndLock() async throws {
        let pds = FakeAccountPDS(password: "hunter2", scope: "com.atproto.access")
        let manager = try await AppPasswordManager.unlock(account: account, password: "hunter2", transport: pds)

        #expect(try await manager.list().map(\.name) == ["newer", "older"])  // newest first
        let created = try await manager.create(name: "laptop-cli")
        #expect(created.name == "laptop-cli")
        #expect(created.password == "aaaa-bbbb-cccc-dddd")
        try await manager.revoke(name: "older")
        await manager.lock()

        #expect(
            pds.calls == [
                "createSession", "listAppPasswords", "createAppPassword", "revokeAppPassword", "deleteSession",
            ])
        // Signed in by DID with the main password; then used that session, not the OAuth one.
        #expect(pds.bodies["createSession"]?["identifier"] as? String == "did:plc:alice")
        #expect(pds.bodies["revokeAppPassword"]?["name"] as? String == "older")
        #expect(pds.authorizations.dropFirst().allSatisfy { $0.hasPrefix("Bearer full-") })
    }

    @Test func wrongPassword() async throws {
        let pds = FakeAccountPDS(password: "hunter2", scope: "com.atproto.access")
        await #expect(throws: ATDriveError.loginFailed("wrong password")) {
            _ = try await AppPasswordManager.unlock(account: account, password: "nope", transport: pds)
        }
    }

    @Test func refusesAnAppPasswordAndEndsThatSession() async throws {
        let pds = FakeAccountPDS(password: "aaaa-bbbb-cccc-dddd", scope: "com.atproto.appPass")
        await #expect(throws: ATDriveError.self) {
            _ = try await AppPasswordManager.unlock(account: account, password: "aaaa-bbbb-cccc-dddd", transport: pds)
        }
        #expect(pds.calls == ["createSession", "deleteSession"])
    }
}

/// Just the account endpoints app-password management uses.
final class FakeAccountPDS: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let password: String
    private let scope: String
    private(set) var calls: [String] = []
    private(set) var bodies: [String: [String: Any]] = [:]
    private(set) var authorizations: [String] = []

    init(password: String, scope: String) {
        self.password = password
        self.scope = scope
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { handle(request) }
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let method = String(request.url!.lastPathComponent.split(separator: ".").last!)
        calls.append(method)
        authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        bodies[method] = body
        switch method {
        case "createSession":
            guard body["password"] as? String == password else {
                return json(["error": "AuthenticationRequired", "message": "Invalid identifier or password"], 401)
            }
            return json([
                "did": "did:plc:alice", "handle": "alice.test",
                "accessJwt": jwt(scope: scope, tag: "access"),
                "refreshJwt": jwt(scope: "com.atproto.refresh", tag: "refresh"),
            ])
        case "listAppPasswords":
            return json([
                "passwords": [
                    ["name": "older", "createdAt": "2026-01-01T00:00:00.000Z"],
                    ["name": "newer", "createdAt": "2026-06-01T00:00:00.000Z"],
                ]
            ])
        case "createAppPassword":
            return json([
                "name": body["name"] ?? "", "password": "aaaa-bbbb-cccc-dddd", "createdAt": "2026-11-09T00:00:00.000Z",
            ])
        case "revokeAppPassword", "deleteSession":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        default:
            return json(["error": "MethodNotImplemented"], 501)
        }
    }

    /// An unsigned stand-in for the PDS's JWTs; only the `scope` claim matters here.
    private func jwt(scope: String, tag: String) -> String {
        let payload = Base64URL.encode(try! JSONSerialization.data(withJSONObject: ["scope": scope]))
        return "full-\(tag).\(payload).signature"
    }

    private func json(_ object: Any, _ status: Int = 200) -> (Data, HTTPURLResponse) {
        (
            try! JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(
                url: URL(string: "https://pds.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

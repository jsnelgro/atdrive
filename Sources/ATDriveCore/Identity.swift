import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Who an account is and where its data lives.
public struct ResolvedIdentity: Sendable {
    public let did: String
    public let handle: String?
    public let pds: URL
}

/// Turns a handle (`alice.example.com`) or DID into the account's PDS URL, by following the
/// same steps any atproto app does: handle → DID → DID document → `#atproto_pds` service.
public struct IdentityResolver: Sendable {
    /// Where `did:plc` documents are published. Override with `ATDRIVE_PLC_URL`.
    public var plcDirectory: URL
    /// Any atproto service that answers `com.atproto.identity.resolveHandle`; used when a handle
    /// has no `/.well-known/atproto-did`. Override with `ATDRIVE_HANDLE_RESOLVER`.
    public var handleResolver: URL
    let transport: any HTTPTransport

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        plcDirectory = URL(string: environment["ATDRIVE_PLC_URL"] ?? "https://plc.directory")!
        handleResolver = URL(
            string: environment["ATDRIVE_HANDLE_RESOLVER"] ?? "https://public.api.bsky.app")!
        self.transport = transport
    }

    public func resolve(_ identifier: String) async throws -> ResolvedIdentity {
        var identifier = identifier.trimmingCharacters(in: .whitespaces)
        if identifier.hasPrefix("@") { identifier.removeFirst() }
        identifier = identifier.lowercased()

        let did = identifier.hasPrefix("did:") ? identifier : try await resolveHandle(identifier)
        let document = try await resolveDID(did)
        guard let pds = document.pdsEndpoint else {
            throw ATDriveError.identity("\(did) has no PDS listed in its DID document")
        }
        let handle =
            identifier.hasPrefix("did:")
            ? document.alsoKnownAs?.first { $0.hasPrefix("at://") }.map { String($0.dropFirst(5)) }
            : identifier
        return ResolvedIdentity(did: did, handle: handle, pds: pds)
    }

    public func resolveHandle(_ handle: String) async throws -> String {
        if let url = URL(string: "https://\(handle)/.well-known/atproto-did"),
            let (data, response) = try? await transport.send(URLRequest(url: url)),
            response.statusCode == 200
        {
            let did = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if did.hasPrefix("did:") { return did }
        }
        struct Output: Decodable { var did: String }
        do {
            return try await XRPCClient(service: handleResolver, transport: transport)
                .query("com.atproto.identity.resolveHandle", ["handle": handle], as: Output.self).did
        } catch {
            throw ATDriveError.identity("couldn't resolve handle \(handle): \(error)")
        }
    }

    public func resolveDID(_ did: String) async throws -> DIDDocument {
        let url: URL
        if did.hasPrefix("did:plc:") {
            url = plcDirectory.appendingPathComponent(did)
        } else if did.hasPrefix("did:web:") {
            let host = String(did.dropFirst("did:web:".count)).removingPercentEncoding ?? ""
            guard !host.contains(":") || host.split(separator: ":").count == 2,
                let parsed = URL(string: "https://\(host)/.well-known/did.json")
            else { throw ATDriveError.identity("unsupported did:web \(did)") }
            url = parsed
        } else {
            throw ATDriveError.identity("unsupported DID method: \(did)")
        }
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard response.statusCode == 200 else {
            throw ATDriveError.identity("couldn't fetch DID document for \(did) (HTTP \(response.statusCode))")
        }
        do {
            return try JSONDecoder().decode(DIDDocument.self, from: data)
        } catch {
            throw ATDriveError.identity("invalid DID document for \(did): \(error)")
        }
    }
}

public struct DIDDocument: Decodable, Sendable {
    public struct Service: Decodable, Sendable {
        public var id: String
        public var type: String
        public var serviceEndpoint: String?

        private enum CodingKeys: String, CodingKey { case id, type, serviceEndpoint }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            // The DID spec allows non-string endpoints; atproto only uses strings.
            serviceEndpoint = try? container.decode(String.self, forKey: .serviceEndpoint)
        }
    }

    public var id: String
    public var alsoKnownAs: [String]?
    public var service: [Service]?

    public var pdsEndpoint: URL? {
        service?
            .first {
                ($0.id == "#atproto_pds" || $0.id == "\(id)#atproto_pds") && $0.type == "AtprotoPersonalDataServer"
            }
            .flatMap { $0.serviceEndpoint }
            .flatMap(URL.init(string:))
    }
}

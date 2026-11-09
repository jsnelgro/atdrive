import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The one place ATDrive touches the network. Tests swap in a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // The completion-handler API behaves the same on macOS and Linux; the async one doesn't.
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }
}

extension HTTPURLResponse {
    func header(_ name: String) -> String? {
        value(forHTTPHeaderField: name)
    }
}

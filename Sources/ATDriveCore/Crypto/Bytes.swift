import Foundation

/// Raw bytes in a record. atproto JSON has no byte strings, so it writes them as
/// `{"$bytes": "<base64>"}`: the standard alphabet, without padding. Padded input is accepted too.
public struct Bytes: Codable, Sendable, Hashable {
    public var data: Data

    public init(_ data: Data) {
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case bytes = "$bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let string = try container.decode(String.self, forKey: .bytes)
        guard let data = Base64.decode(string) else {
            throw DecodingError.dataCorruptedError(forKey: .bytes, in: container, debugDescription: "not base64")
        }
        self.data = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Base64.encode(data), forKey: .bytes)
    }
}

/// Standard base64 without padding, as atproto writes bytes.
enum Base64 {
    static func encode(_ data: Data) -> String {
        var string = data.base64EncodedString()
        while string.hasSuffix("=") { string.removeLast() }
        return string
    }

    /// Accepts padded and unpadded input. Foundation insists on padding, so it's put back first.
    static func decode(_ string: String) -> Data? {
        var unpadded = Substring(string)
        while unpadded.hasSuffix("=") { unpadded.removeLast() }
        guard unpadded.count % 4 != 1 else { return nil }
        return Data(base64Encoded: unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4))
    }
}

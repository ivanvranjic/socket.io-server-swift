import Foundation

struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension SocketIOConfiguration {
    /// Encodes `[first, items...]` as a JSON array.
    func encodeArray(first: String?, items: [any Encodable]) throws -> String {
        var elements: [AnyEncodable] = []
        if let first { elements.append(AnyEncodable(value: first)) }
        elements.append(contentsOf: items.map { AnyEncodable(value: $0) })
        let data = try encoder.encode(elements)
        return String(decoding: data, as: UTF8.self)
    }

    func decodeArray(_ payload: String) -> [JSONValue]? {
        try? decoder.decode([JSONValue].self, from: Data(payload.utf8))
    }

    func encodeObject(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

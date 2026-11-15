import Foundation

/// Socket.IO packet types (protocol v5, Engine.IO v4).
enum PacketType: Int {
    case connect = 0
    case disconnect = 1
    case event = 2
    case ack = 3
    case connectError = 4
    case binaryEvent = 5
    case binaryAck = 6
}

/// A decoded Socket.IO packet. `payload` is the raw JSON text that follows the header.
struct Packet: Equatable {
    var type: PacketType
    var namespace: String
    var id: Int?
    var payload: String

    init(type: PacketType, namespace: String = "/", id: Int? = nil, payload: String = "") {
        self.type = type
        self.namespace = namespace
        self.id = id
        self.payload = payload
    }

    /// `<type>[<attachments>-][<namespace>,][<id>]<payload>`
    func encoded() -> String {
        var s = String(type.rawValue)
        if namespace != "/" {
            s += namespace
            s += ","
        }
        if let id { s += String(id) }
        s += payload
        return s
    }

    static func decode(_ text: String) -> Packet? {
        var chars = Substring(text)
        guard let first = chars.first, let digit = first.wholeNumberValue,
              let type = PacketType(rawValue: digit) else { return nil }
        chars = chars.dropFirst()

        // Binary packets carry "<count>-" before the namespace.
        if type == .binaryEvent || type == .binaryAck {
            guard let dash = chars.firstIndex(of: "-") else { return nil }
            chars = chars[chars.index(after: dash)...]
        }

        var namespace = "/"
        if chars.first == "/" {
            if let comma = chars.firstIndex(of: ",") {
                namespace = String(chars[..<comma])
                chars = chars[chars.index(after: comma)...]
            } else {
                namespace = String(chars)
                chars = ""
            }
        }

        var id: Int?
        let digits = chars.prefix(while: { $0.isASCII && $0.isNumber })
        // An id is only valid for event/ack packets; for others digits can't legally appear.
        if !digits.isEmpty, type == .event || type == .ack || type == .binaryEvent || type == .binaryAck {
            id = Int(digits)
            chars = chars.dropFirst(digits.count)
        }

        return Packet(type: type, namespace: namespace, id: id, payload: String(chars))
    }
}

/// Engine.IO packet types (protocol v4).
enum EnginePacket {
    static let open = "0"
    static let close = "1"
    static let ping = "2"
    static let pong = "3"
    static let message = "4"
}

import Foundation

/// Sends an acknowledgement back to the client that emitted the event.
public struct SocketIOAck: Sendable {
    let send: @Sendable ([any Encodable]) throws -> Void

    public func callAsFunction(_ items: any Encodable...) throws {
        try send(items)
    }
}

/// An event received from a client.
public struct SocketIOEvent: Sendable {
    public let socket: SocketIOSocket
    public let name: String
    public let args: [JSONValue]
    /// Non-nil when the client asked for an acknowledgement.
    public let ack: SocketIOAck?

    /// Decodes the argument at `index` into `T`.
    public func decode<T: Decodable>(_ type: T.Type = T.self, at index: Int = 0) throws -> T {
        guard args.indices.contains(index) else { throw SocketIOError.missingArgument(index) }
        return try args[index].decode(T.self, using: socket.configuration.decoder)
    }
}

public typealias SocketIOEventHandler = @Sendable (SocketIOEvent) async throws -> Void

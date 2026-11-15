import Foundation

public struct SocketIOConfiguration: @unchecked Sendable {
    /// How often the server pings each client, in seconds.
    public var pingInterval: TimeInterval = 25
    /// How long the server waits for a pong before closing the connection, in seconds.
    public var pingTimeout: TimeInterval = 20
    /// How long a new connection may stay without connecting to any namespace, in seconds.
    public var connectTimeout: TimeInterval = 45
    /// Maximum size of a single incoming message, in bytes.
    public var maxPayload: Int = 1_000_000
    public var encoder: JSONEncoder = JSONEncoder()
    public var decoder: JSONDecoder = JSONDecoder()

    public init() {}
}

/// Why a socket was disconnected.
public enum DisconnectReason: String, Sendable {
    /// The client called `socket.disconnect()`.
    case clientNamespaceDisconnect = "client namespace disconnect"
    /// The server called `socket.disconnect()`.
    case serverNamespaceDisconnect = "server namespace disconnect"
    /// The underlying connection was closed.
    case transportClose = "transport close"
    /// The client stopped answering pings.
    case pingTimeout = "ping timeout"
    /// The server shut down.
    case serverShuttingDown = "server shutting down"
}

/// Thrown from a namespace middleware to reject a connection. The message and data are sent to the client.
public struct SocketIOConnectError: Error, Sendable {
    public var message: String
    public var data: JSONValue?
    public init(_ message: String, data: JSONValue? = nil) {
        self.message = message
        self.data = data
    }
}

public enum SocketIOError: Error, Sendable {
    case ackTimeout
    case disconnected
    case missingArgument(Int)
}

import Foundation
import NIOConcurrencyHelpers
import Logging

/// A Socket.IO v4 server. It is transport-agnostic: an adapter (such as `SocketIOVapor`) opens a
/// ``SocketIOTransport`` per client and passes it to ``accept(transport:request:)``.
///
/// ```swift
/// let io = SocketIOServer()
/// io.onConnection { socket in
///     socket.on("chat") { event in
///         socket.broadcast.emit("chat", try event.decode(String.self))
///     }
/// }
/// ```
public final class SocketIOServer: @unchecked Sendable {
    public let configuration: SocketIOConfiguration
    public let logger: Logger
    private let namespaces = NIOLockedValueBox<[String: SocketIONamespace]>([:])
    private let storage = NIOLockedValueBox<[String: any Sendable]>([:])

    public init(configuration: SocketIOConfiguration = SocketIOConfiguration(), logger: Logger = Logger(label: "socket.io")) {
        self.configuration = configuration
        self.logger = logger
        _ = namespace("/")
    }

    /// Server-wide storage, e.g. for adapters to attach the host framework's application object.
    public subscript(storage key: String) -> (any Sendable)? {
        get { storage.withLockedValue { $0[key] } }
        set { storage.withLockedValue { $0[key] = newValue } }
    }

    /// Registers a new client connection. The caller must forward the transport's incoming frames to the
    /// returned connection's `receive(text:)` and call `transportDidClose()` when it closes.
    @discardableResult
    public func accept(transport: SocketIOTransport, request: SocketIOUpgradeRequest = SocketIOUpgradeRequest()) -> SocketIOConnection {
        let connection = SocketIOConnection(transport: transport, request: request, server: self)
        connection.start()
        return connection
    }

    /// Returns the namespace named `name`, creating it if needed. A leading `/` is added when missing.
    @discardableResult
    public func namespace(_ name: String) -> SocketIONamespace {
        let name = name.hasPrefix("/") ? name : "/" + name
        return namespaces.withLockedValue { all in
            if let existing = all[name] { return existing }
            let created = SocketIONamespace(name: name, configuration: configuration, logger: logger)
            all[name] = created
            return created
        }
    }

    func existingNamespace(_ name: String) -> SocketIONamespace? {
        namespaces.withLockedValue { $0[name] }
    }

    /// The default namespace (`/`).
    public var main: SocketIONamespace { namespace("/") }

    // MARK: Default namespace shortcuts

    public func use(_ middleware: @escaping SocketIOMiddleware) { main.use(middleware) }
    public func onConnection(_ handler: @escaping SocketIOConnectionHandler) { main.onConnection(handler) }
    public func emit(_ event: String, _ items: any Encodable...) {
        main.broadcast(event: event, items: items, operator: BroadcastOperator(namespace: main))
    }
    public func to(_ rooms: String...) -> BroadcastOperator { BroadcastOperator(namespace: main).to(rooms) }
    public func except(_ rooms: String...) -> BroadcastOperator { BroadcastOperator(namespace: main).except(rooms) }

    /// Disconnects every client. Adapters call this on application shutdown.
    public func shutdown() {
        for ns in namespaces.withLockedValue({ Array($0.values) }) {
            ns.disconnectSockets()
        }
    }
}

private extension SocketIONamespace {
    func disconnectSockets() {
        for socket in sockets { socket.disconnect(closeConnection: true) }
    }
}

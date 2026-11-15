import Foundation
import NIOConcurrencyHelpers
import Vapor

/// A Socket.IO v4 server mounted on a Vapor application.
///
/// ```swift
/// let io = app.socketIO.configure()           // mounts /socket.io
/// io.onConnection { socket in
///     socket.on("chat") { event in
///         socket.broadcast.emit("chat", try event.decode(String.self))
///     }
/// }
/// ```
public final class SocketIOServer: @unchecked Sendable {
    public let configuration: SocketIOConfiguration
    let application: Application
    private let namespaces = NIOLockedValueBox<[String: SocketIONamespace]>([:])

    init(application: Application, configuration: SocketIOConfiguration) {
        self.application = application
        self.configuration = configuration
        _ = namespace("/")
    }

    /// Returns the namespace named `name`, creating it if needed. A leading `/` is added when missing.
    @discardableResult
    public func namespace(_ name: String) -> SocketIONamespace {
        let name = name.hasPrefix("/") ? name : "/" + name
        return namespaces.withLockedValue { all in
            if let existing = all[name] { return existing }
            let created = SocketIONamespace(name: name, configuration: configuration, logger: application.logger)
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

    // MARK: Routing

    func mount() {
        let path = PathComponent(stringLiteral: configuration.path)
        application.webSocket(
            path,
            maxFrameSize: WebSocketMaxFrameSize(integerLiteral: configuration.maxPayload),
            shouldUpgrade: { req in
                let items = URLComponents(string: req.url.string)?.queryItems ?? []
                func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
                guard value("EIO") == "4", value("transport") == "websocket" else {
                    throw Abort(.badRequest, reason: "Only Engine.IO v4 over WebSocket is supported. Set transports: [\"websocket\"] on the client.")
                }
                return [:]
            },
            onUpgrade: { [self] req, ws in
                let connection = EngineConnection(ws: ws, req: req, server: self)
                // WebSocket callbacks must be installed on the socket's event loop.
                ws.eventLoop.execute { connection.start() }
            }
        )
    }

    /// Disconnects every client. Called automatically on application shutdown.
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

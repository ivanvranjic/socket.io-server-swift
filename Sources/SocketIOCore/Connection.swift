import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOHTTP1

/// The underlying duplex text channel, normally a WebSocket. Adapters implement this and feed
/// incoming frames to ``SocketIOConnection/receive(text:)``.
public protocol SocketIOTransport: AnyObject, Sendable {
    /// Sends one text frame. Must preserve call order.
    func send(_ text: String)
    /// Closes the channel. Must be safe to call more than once.
    func close()
}

/// The HTTP upgrade request that opened a transport.
public struct SocketIOUpgradeRequest: Sendable {
    public var headers: HTTPHeaders
    public var url: String
    public var query: [String: String]
    public var remoteAddress: String?

    public init(headers: HTTPHeaders = [:], url: String = "/socket.io/", query: [String: String] = [:], remoteAddress: String? = nil) {
        self.headers = headers
        self.url = url
        self.query = query
        self.remoteAddress = remoteAddress
    }
}

/// One Engine.IO connection (a single transport), which can host one socket per namespace.
public final class SocketIOConnection: @unchecked Sendable {
    let sid: String
    private let transport: SocketIOTransport
    private let server: SocketIOServer
    private let request: SocketIOUpgradeRequest
    private let logger: Logger
    private var configuration: SocketIOConfiguration { server.configuration }

    private struct State {
        var sockets: [String: SocketIOSocket] = [:]  // by namespace name
        var closed = false
        var pongReceived = true
        var sawConnect = false
        var tasks: [Task<Void, Never>] = []
    }
    private let state = NIOLockedValueBox(State())

    private enum Incoming {
        case connect(namespace: String, auth: JSONValue?)
        case event(namespace: String, id: Int?, args: [JSONValue])
        case disconnect(namespace: String)
    }
    private let incoming: AsyncStream<Incoming>
    private let incomingContinuation: AsyncStream<Incoming>.Continuation

    init(transport: SocketIOTransport, request: SocketIOUpgradeRequest, server: SocketIOServer) {
        self.sid = Self.makeId()
        self.transport = transport
        self.server = server
        self.request = request
        self.logger = server.logger
        (incoming, incomingContinuation) = AsyncStream.makeStream()
    }

    static func makeId() -> String {
        // 20 url-safe characters, similar to the ids socket.io generates.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return String((0..<20).map { _ in alphabet.randomElement()! })
    }

    // MARK: Lifecycle

    func start() {
        let config = configuration
        let open = """
        {"sid":"\(sid)","upgrades":[],"pingInterval":\(Int(config.pingInterval * 1000)),"pingTimeout":\(Int(config.pingTimeout * 1000)),"maxPayload":\(config.maxPayload)}
        """
        send(EnginePacket.open + open)

        let consumer = Task { [weak self] in
            guard let self else { return }
            for await packet in self.incoming {
                await self.process(packet)
            }
        }
        let pinger = Task<Void, Never> { [weak self] in await self?.runPing() }
        let connectTimeout = Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(config.connectTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.state.withLockedValue({ $0.sockets.isEmpty }) { self.close() }
        }
        state.withLockedValue { $0.tasks = [consumer, pinger, connectTimeout] }
    }

    func send(_ text: String) {
        guard !state.withLockedValue({ $0.closed }) else { return }
        transport.send(text)
    }

    func close() {
        finish(reason: .transportClose)
    }

    // MARK: Transport input

    /// Feed every text frame received on the transport here.
    public func receive(text: String) {
        handle(text: text)
    }

    /// Feed binary frames here. They are not supported and are only logged.
    public func receiveBinary() {
        logger.warning("Socket.IO \(sid): binary packets are not supported")
    }

    /// Call when the transport has closed (for any reason).
    public func transportDidClose() {
        finish(reason: .transportClose)
    }

    func finish(reason: DisconnectReason) {
        let (sockets, tasks): ([SocketIOSocket], [Task<Void, Never>]) = state.withLockedValue { s in
            guard !s.closed else { return ([], []) }
            s.closed = true
            let result = (Array(s.sockets.values), s.tasks)
            s.sockets = [:]
            s.tasks = []
            return result
        }
        guard !(sockets.isEmpty && tasks.isEmpty) else { return }
        incomingContinuation.finish()
        for t in tasks { t.cancel() }
        transport.close()
        Task {
            for socket in sockets { await socket.didDisconnect(reason) }
        }
    }

    func removeSocket(_ socket: SocketIOSocket) {
        state.withLockedValue { $0.sockets[socket.namespace.name] = nil }
    }

    // MARK: Heartbeat

    private func runPing() async {
        let interval = UInt64(configuration.pingInterval * 1_000_000_000)
        let timeout = UInt64(configuration.pingTimeout * 1_000_000_000)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { return }
            state.withLockedValue { $0.pongReceived = false }
            send(EnginePacket.ping)
            try? await Task.sleep(nanoseconds: timeout)
            if Task.isCancelled { return }
            if !state.withLockedValue({ $0.pongReceived }) {
                finish(reason: .pingTimeout)
                return
            }
        }
    }

    // MARK: Incoming

    private func handle(text: String) {
        guard let kind = text.first else { return }
        switch String(kind) {
        case EnginePacket.pong:
            state.withLockedValue { $0.pongReceived = true }
        case EnginePacket.ping:
            send(EnginePacket.pong + text.dropFirst())
        case EnginePacket.close:
            close()
        case EnginePacket.message:
            guard text.utf8.count <= configuration.maxPayload else {
                logger.warning("Socket.IO \(sid): payload too large, closing")
                close()
                return
            }
            handle(packet: String(text.dropFirst()))
        default:
            break
        }
    }

    private func handle(packet text: String) {
        guard let packet = Packet.decode(text) else {
            logger.warning("Socket.IO \(sid): malformed packet, closing")
            close()
            return
        }
        // Spec: the first packet must be CONNECT, otherwise the server closes the connection.
        let valid = state.withLockedValue { s -> Bool in
            if packet.type == .connect { s.sawConnect = true }
            return s.sawConnect
        }
        guard valid else {
            logger.warning("Socket.IO \(sid): first packet was not CONNECT, closing")
            close()
            return
        }
        switch packet.type {
        case .connect:
            let auth = packet.payload.isEmpty ? nil : configuration.decodeAny(packet.payload)
            incomingContinuation.yield(.connect(namespace: packet.namespace, auth: auth))
        case .disconnect:
            incomingContinuation.yield(.disconnect(namespace: packet.namespace))
        case .event:
            // Spec: an EVENT payload must be a non-empty array starting with the event name.
            guard let array = configuration.decodeArray(packet.payload),
                  array.first?.stringValue != nil else {
                logger.warning("Socket.IO \(sid): invalid event payload, closing")
                close()
                return
            }
            incomingContinuation.yield(.event(namespace: packet.namespace, id: packet.id, args: array))
        case .ack:
            // Handled immediately so a handler awaiting `emitWithAck` can't block its own ack.
            guard let id = packet.id, let socket = socket(for: packet.namespace) else { return }
            socket.resolveAck(id: id, result: .success(configuration.decodeArray(packet.payload) ?? []))
        case .binaryEvent, .binaryAck:
            logger.warning("Socket.IO \(sid): binary events are not supported")
        case .connectError:
            break
        }
    }

    private func socket(for namespace: String) -> SocketIOSocket? {
        state.withLockedValue { $0.sockets[namespace] }
    }

    private func process(_ packet: Incoming) async {
        switch packet {
        case .connect(let nsp, let auth):
            await connect(namespace: nsp, auth: auth)
        case .disconnect(let nsp):
            await socket(for: nsp)?.didDisconnect(.clientNamespaceDisconnect)
        case .event(let nsp, let id, let args):
            await dispatch(namespace: nsp, id: id, array: args)
        }
    }

    private func connect(namespace name: String, auth: JSONValue?) async {
        guard socket(for: name) == nil else { return }
        guard let namespace = server.existingNamespace(name) else {
            sendConnectError(namespace: name, message: "Invalid namespace")
            return
        }
        let handshake = SocketIOHandshake(
            headers: request.headers,
            url: request.url,
            query: request.query,
            remoteAddress: request.remoteAddress,
            auth: auth
        )
        let socket = SocketIOSocket(
            id: Self.makeId(),
            namespace: namespace,
            handshake: handshake,
            connection: self,
            server: server,
            configuration: configuration
        )

        do {
            for middleware in namespace.middlewares { try await middleware(socket) }
        } catch let error as SocketIOConnectError {
            sendConnectError(namespace: name, message: error.message, data: error.data)
            return
        } catch {
            logger.warning("Socket.IO middleware failed: \(error)")
            sendConnectError(namespace: name, message: "Connection rejected")
            return
        }

        let registered = state.withLockedValue { s -> Bool in
            guard !s.closed else { return false }
            s.sockets[name] = socket
            return true
        }
        guard registered else { return }
        namespace.add(socket)

        socket.sendPacket(Packet(type: .connect, namespace: name, payload: "{\"sid\":\"\(socket.id)\"}"))
        for handler in namespace.connectionHandlers { await handler(socket) }
    }

    private func sendConnectError(namespace: String, message: String, data: JSONValue? = nil) {
        struct Body: Encodable { let message: String; let data: JSONValue? }
        let payload = configuration.encodeObject(Body(message: message, data: data))
        send(EnginePacket.message + Packet(type: .connectError, namespace: namespace, payload: payload).encoded())
    }

    private func dispatch(namespace: String, id: Int?, array: [JSONValue]) async {
        guard let socket = socket(for: namespace),
              let name = array.first?.stringValue else { return }
        let event = SocketIOEvent(
            socket: socket,
            name: name,
            args: Array(array.dropFirst()),
            ack: id.map { socket.makeAck(id: $0) }
        )
        for handler in socket.handlers(for: name) {
            do {
                try await handler(event)
            } catch {
                logger.error("Socket.IO handler for '\(name)' threw: \(error)")
            }
        }
    }
}

private extension SocketIOConfiguration {
    func decodeAny(_ payload: String) -> JSONValue? {
        try? decoder.decode(JSONValue.self, from: Data(payload.utf8))
    }
}

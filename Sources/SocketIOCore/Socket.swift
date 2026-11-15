import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOHTTP1

/// Information captured from the HTTP upgrade request and the client's CONNECT packet.
public struct SocketIOHandshake: Sendable {
    public let headers: HTTPHeaders
    public let url: String
    /// Query parameters of the upgrade request, including the Engine.IO ones (`EIO`, `transport`).
    public let query: [String: String]
    public let remoteAddress: String?
    /// The `auth` object the client passed to `io(url, { auth })`.
    public let auth: JSONValue?
}

public final class SocketIOSocket: @unchecked Sendable {
    public let id: String
    public let namespace: SocketIONamespace
    public let handshake: SocketIOHandshake
    public let server: SocketIOServer
    public let logger: Logger
    let configuration: SocketIOConfiguration
    private let connection: SocketIOConnection

    private struct State {
        var handlers: [String: [SocketIOEventHandler]] = [:]
        var disconnectHandlers: [@Sendable (DisconnectReason) async -> Void] = []
        var pendingAcks: [Int: CheckedContinuation<[JSONValue], Error>] = [:]
        var nextAckId = 0
        var connected = true
        var userInfo: [String: any Sendable] = [:]
    }
    private let state = NIOLockedValueBox(State())

    init(
        id: String,
        namespace: SocketIONamespace,
        handshake: SocketIOHandshake,
        connection: SocketIOConnection,
        server: SocketIOServer,
        configuration: SocketIOConfiguration
    ) {
        self.id = id
        self.namespace = namespace
        self.handshake = handshake
        self.connection = connection
        self.server = server
        self.configuration = configuration
        self.logger = server.logger
    }

    public var isConnected: Bool { state.withLockedValue { $0.connected } }

    /// Arbitrary per-socket storage, e.g. the authenticated user set by a middleware.
    public var userInfo: [String: any Sendable] {
        get { state.withLockedValue { $0.userInfo } }
        set { state.withLockedValue { $0.userInfo = newValue } }
    }

    public func setUserInfo(_ key: String, _ value: (any Sendable)?) {
        state.withLockedValue { $0.userInfo[key] = value }
    }

    // MARK: Receiving

    /// Registers a handler for `event`.
    public func on(_ event: String, _ handler: @escaping SocketIOEventHandler) {
        state.withLockedValue { $0.handlers[event, default: []].append(handler) }
    }

    /// Registers a handler that receives the first argument decoded as `T`. Decoding failures are logged and the event is dropped.
    public func on<T: Decodable>(
        _ event: String,
        as type: T.Type = T.self,
        _ handler: @escaping @Sendable (SocketIOEvent, T) async throws -> Void
    ) {
        on(event) { e in
            let value: T
            do {
                value = try e.decode(T.self)
            } catch {
                e.socket.logger.warning("Socket.IO '\(event)' from \(e.socket.id): invalid payload: \(error)")
                return
            }
            try await handler(e, value)
        }
    }

    /// Registers a handler that runs once when the socket disconnects.
    public func onDisconnect(_ handler: @escaping @Sendable (DisconnectReason) async -> Void) {
        state.withLockedValue { $0.disconnectHandlers.append(handler) }
    }

    func handlers(for event: String) -> [SocketIOEventHandler] {
        state.withLockedValue { $0.handlers[event] ?? [] }
    }

    // MARK: Sending

    /// Emits an event to this client.
    public func emit(_ event: String, _ items: any Encodable...) {
        send(event: event, items: items, id: nil)
    }

    /// Emits an event and waits for the client's acknowledgement.
    public func emitWithAck(
        _ event: String,
        timeout: TimeInterval = 10,
        _ items: any Encodable...
    ) async throws -> [JSONValue] {
        let payload = try configuration.encodeArray(first: event, items: items)
        let id: Int? = state.withLockedValue { s in
            guard s.connected else { return nil }
            s.nextAckId += 1
            return s.nextAckId
        }
        guard let id else { throw SocketIOError.disconnected }

        return try await withCheckedThrowingContinuation { continuation in
            let registered = state.withLockedValue { s -> Bool in
                guard s.connected else { return false }
                s.pendingAcks[id] = continuation
                return true
            }
            guard registered else {
                continuation.resume(throwing: SocketIOError.disconnected)
                return
            }
            sendPacket(Packet(type: .event, namespace: namespace.name, id: id, payload: payload))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolveAck(id: id, result: .failure(SocketIOError.ackTimeout))
            }
        }
    }

    private func send(event: String, items: [any Encodable], id: Int?) {
        do {
            let payload = try configuration.encodeArray(first: event, items: items)
            sendPacket(Packet(type: .event, namespace: namespace.name, id: id, payload: payload))
        } catch {
            logger.error("Failed to encode '\(event)' for \(self.id): \(error)")
        }
    }

    func sendPacket(_ packet: Packet) {
        sendRaw(EnginePacket.message + packet.encoded())
    }

    func sendRaw(_ text: String) {
        guard isConnected else { return }
        connection.send(text)
    }

    func makeAck(id: Int) -> SocketIOAck {
        SocketIOAck { [weak self] items in
            guard let self else { return }
            let payload = try self.configuration.encodeArray(first: nil, items: items)
            self.sendPacket(Packet(type: .ack, namespace: self.namespace.name, id: id, payload: payload))
        }
    }

    func resolveAck(id: Int, result: Result<[JSONValue], Error>) {
        let continuation = state.withLockedValue { $0.pendingAcks.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    // MARK: Rooms & broadcasting

    public func join(_ room: String) { namespace.join(id, room: room) }
    public func leave(_ room: String) { namespace.leave(id, room: room) }
    /// Rooms this socket is in, including its own id.
    public var rooms: Set<String> { namespace.rooms(of: id) }

    /// Broadcast to `rooms`, excluding this socket: `socket.to("room").emit(...)`.
    public func to(_ rooms: String...) -> BroadcastOperator {
        var op = BroadcastOperator(namespace: namespace).to(rooms)
        op.exceptSocketIds.insert(id)
        return op
    }

    /// Broadcast to every socket in the namespace except this one.
    public var broadcast: BroadcastOperator {
        var op = BroadcastOperator(namespace: namespace)
        op.exceptSocketIds.insert(id)
        return op
    }

    // MARK: Disconnecting

    /// Disconnects this socket from its namespace. With `closeConnection`, the whole transport is closed too.
    public func disconnect(closeConnection: Bool = false) {
        if isConnected {
            sendPacket(Packet(type: .disconnect, namespace: namespace.name))
        }
        Task { await self.didDisconnect(.serverNamespaceDisconnect) }
        if closeConnection { connection.close() }
    }

    func didDisconnect(_ reason: DisconnectReason) async {
        let (handlers, pending): ([@Sendable (DisconnectReason) async -> Void], [CheckedContinuation<[JSONValue], Error>]) =
            state.withLockedValue { s in
                guard s.connected else { return ([], []) }
                s.connected = false
                let pending = Array(s.pendingAcks.values)
                s.pendingAcks = [:]
                return (s.disconnectHandlers, pending)
            }
        namespace.remove(self)
        connection.removeSocket(self)
        for p in pending { p.resume(throwing: SocketIOError.disconnected) }
        for handler in handlers { await handler(reason) }
    }
}

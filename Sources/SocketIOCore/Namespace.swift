import Foundation
import Logging
import NIOConcurrencyHelpers

public typealias SocketIOMiddleware = @Sendable (SocketIOSocket) async throws -> Void
public typealias SocketIOConnectionHandler = @Sendable (SocketIOSocket) async -> Void

public final class SocketIONamespace: @unchecked Sendable {
    public let name: String
    let configuration: SocketIOConfiguration
    let logger: Logger

    private struct State {
        var sockets: [String: SocketIOSocket] = [:]
        var rooms: [String: Set<String>] = [:]
        var middlewares: [SocketIOMiddleware] = []
        var connectionHandlers: [SocketIOConnectionHandler] = []
    }
    private let state = NIOLockedValueBox(State())

    init(name: String, configuration: SocketIOConfiguration, logger: Logger) {
        self.name = name
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: Registration

    /// Runs before a socket is connected. Throw `SocketIOConnectError` to reject it.
    /// Use `socket.handshake.auth` to authenticate and `socket.userInfo` to store the result.
    public func use(_ middleware: @escaping SocketIOMiddleware) {
        state.withLockedValue { $0.middlewares.append(middleware) }
    }

    /// Called for every socket that connects to this namespace. Register event handlers here.
    public func onConnection(_ handler: @escaping SocketIOConnectionHandler) {
        state.withLockedValue { $0.connectionHandlers.append(handler) }
    }

    var middlewares: [SocketIOMiddleware] { state.withLockedValue { $0.middlewares } }
    var connectionHandlers: [SocketIOConnectionHandler] { state.withLockedValue { $0.connectionHandlers } }

    // MARK: Sockets

    public var sockets: [SocketIOSocket] { state.withLockedValue { Array($0.sockets.values) } }

    public func socket(id: String) -> SocketIOSocket? { state.withLockedValue { $0.sockets[id] } }

    func add(_ socket: SocketIOSocket) {
        state.withLockedValue { $0.sockets[socket.id] = socket }
        join(socket.id, room: socket.id)
    }

    func remove(_ socket: SocketIOSocket) {
        state.withLockedValue { state in
            state.sockets[socket.id] = nil
            for room in state.rooms.keys {
                state.rooms[room]?.remove(socket.id)
                if state.rooms[room]?.isEmpty == true { state.rooms[room] = nil }
            }
        }
    }

    // MARK: Rooms

    func join(_ socketId: String, room: String) {
        state.withLockedValue { _ = $0.rooms[room, default: []].insert(socketId) }
    }

    func leave(_ socketId: String, room: String) {
        state.withLockedValue { state in
            state.rooms[room]?.remove(socketId)
            if state.rooms[room]?.isEmpty == true { state.rooms[room] = nil }
        }
    }

    func rooms(of socketId: String) -> Set<String> {
        state.withLockedValue { state in
            Set(state.rooms.compactMap { $0.value.contains(socketId) ? $0.key : nil })
        }
    }

    /// Ids of the sockets currently in `room`.
    public func socketIds(in room: String) -> Set<String> {
        state.withLockedValue { $0.rooms[room] ?? [] }
    }

    // MARK: Broadcasting

    private var all: BroadcastOperator { BroadcastOperator(namespace: self) }

    public func to(_ rooms: String...) -> BroadcastOperator { all.to(rooms) }
    public func except(_ rooms: String...) -> BroadcastOperator { all.except(rooms) }

    /// Emits to every socket in this namespace.
    public func emit(_ event: String, _ items: any Encodable...) {
        broadcast(event: event, items: items, operator: all)
    }

    func matchingSockets(_ op: BroadcastOperator) -> [SocketIOSocket] {
        state.withLockedValue { state in
            var ids: Set<String>
            if op.rooms.isEmpty {
                ids = Set(state.sockets.keys)
            } else {
                ids = []
                for room in op.rooms { ids.formUnion(state.rooms[room] ?? []) }
            }
            for room in op.exceptRooms { ids.subtract(state.rooms[room] ?? []) }
            ids.subtract(op.exceptSocketIds)
            return ids.compactMap { state.sockets[$0] }
        }
    }

    func broadcast(event: String, items: [any Encodable], operator op: BroadcastOperator) {
        let targets = matchingSockets(op)
        guard !targets.isEmpty else { return }
        let payload: String
        do {
            payload = try configuration.encodeArray(first: event, items: items)
        } catch {
            logger.error("Failed to encode broadcast '\(event)': \(error)")
            return
        }
        let text = EnginePacket.message + Packet(type: .event, namespace: name, payload: payload).encoded()
        for socket in targets { socket.sendRaw(text) }
    }
}

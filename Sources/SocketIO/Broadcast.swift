import Foundation

/// Selects a subset of a namespace's sockets and emits to them: `io.to("room").except("other").emit(...)`.
public struct BroadcastOperator: Sendable {
    let namespace: SocketIONamespace
    var rooms: Set<String> = []
    var exceptRooms: Set<String> = []
    var exceptSocketIds: Set<String> = []

    public func to(_ rooms: String...) -> BroadcastOperator { to(rooms) }

    public func to(_ rooms: [String]) -> BroadcastOperator {
        var copy = self
        copy.rooms.formUnion(rooms)
        return copy
    }

    public func except(_ rooms: String...) -> BroadcastOperator { except(rooms) }

    public func except(_ rooms: [String]) -> BroadcastOperator {
        var copy = self
        copy.exceptRooms.formUnion(rooms)
        return copy
    }

    public func emit(_ event: String, _ items: any Encodable...) {
        namespace.broadcast(event: event, items: items, operator: self)
    }

    /// The sockets that match this selection.
    public func fetchSockets() -> [SocketIOSocket] {
        namespace.matchingSockets(self)
    }

    /// Makes all matching sockets join `room`.
    public func socketsJoin(_ room: String) {
        for socket in fetchSockets() { socket.join(room) }
    }

    /// Makes all matching sockets leave `room`.
    public func socketsLeave(_ room: String) {
        for socket in fetchSockets() { socket.leave(room) }
    }

    /// Disconnects all matching sockets.
    public func disconnectSockets(closeConnection: Bool = false) {
        for socket in fetchSockets() { socket.disconnect(closeConnection: closeConnection) }
    }
}

# vapor-socketio

A server-side [Socket.IO](https://socket.io) v4 implementation for [Vapor](https://vapor.codes) 4 (Engine.IO v4 over WebSocket).
Works with the official JS client and `socket.io-client-swift`.

## Usage

```swift
// Package.swift
.package(path: "../vapor-socketio")            // or a git URL
.product(name: "SocketIO", package: "vapor-socketio")
```

```swift
import SocketIO

func configure(_ app: Application) async throws {
    let io = app.socketIO.configure()           // mounts /socket.io

    io.use { socket in                          // auth middleware
        guard let token = socket.handshake.auth?["token"]?.stringValue else {
            throw SocketIOConnectError("unauthorized")
        }
        socket.setUserInfo("userId", try await verify(token, app))
    }

    io.onConnection { socket in
        socket.join("lobby")

        socket.on("chat", as: ChatMessage.self) { event, msg in
            socket.to("lobby").emit("chat", msg)          // everyone else in the room
            try event.ack?("delivered")                   // reply to client's ack callback
        }

        socket.onDisconnect { reason in /* cleanup */ }
    }

    io.namespace("/admin").onConnection { socket in /* ... */ }
}

// From a route handler:
app.post("announce") { req async throws -> HTTPStatus in
    req.socketIO.to("lobby").emit("announcement", "hello")
    return .ok
}
```

Server → client with ack: `let reply = try await socket.emitWithAck("question", timeout: 5, payload)`.

Events are handled in order per connection. Handlers are `async`, so a slow handler delays that client's next event (not other clients').

## Clients (verified: socket.io-client 4.8.1 and socket.io-client-swift 16.1.1)

Only the WebSocket transport is implemented, so clients must skip HTTP long-polling:

- JS: `io(url, { transports: ["websocket"] })`
- Swift: `SocketManager(socketURL: url, config: [.forceWebsockets(true)])`

## Not supported

HTTP long-polling, binary attachments (binary events are logged and dropped), connection state recovery, and multi-node scaling (no adapter; rooms live in process memory).

## Tests

`swift test` runs protocol unit tests. `Tests/Interop/run.sh` starts `Examples/InteropServer` and drives it with the official JS client, the official Swift client (`Tests/InteropSwiftClient`), and a ping-timeout check (needs node; `--no-swift` skips the Swift client).

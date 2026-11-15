# socket.io-server-swift

A server-side [Socket.IO](https://socket.io) v4 implementation in Swift (Engine.IO v4 over WebSocket).
Works with the official JS client and `socket.io-client-swift`. This package is the framework-independent core
(`SocketIOCore`, depends only on swift-nio and swift-log); web frameworks plug in through small adapter packages:

| Package | Framework |
|---|---|
| [`socket.io-server-swift-vapor`](../socket.io-server-swift-vapor) | Vapor 4 |
| [`socket.io-server-swift-hummingbird`](../socket.io-server-swift-hummingbird) | Hummingbird 2 (needs Swift 6.2 / macOS 14) |

Each adapter is its own package so that its framework's platform requirements don't leak into the others.

## API

The same in every adapter (the adapter re-exports `SocketIOCore`; the `io` server comes from the adapter's setup):

```swift
io.use { socket in                          // auth middleware, runs before the socket connects
    guard let token = socket.handshake.auth?["token"]?.stringValue else {
        throw SocketIOConnectError("unauthorized")
    }
    socket.setUserInfo("userId", try await verify(token))
}

io.onConnection { socket in
    socket.join("lobby")

    socket.on("chat", as: ChatMessage.self) { event, msg in
        socket.to("lobby").emit("chat", msg)          // everyone else in the room
        try event.ack?("delivered")                   // reply to the client's ack callback
    }

    socket.onDisconnect { reason in /* cleanup */ }
}

io.namespace("/admin").onConnection { socket in /* ... */ }
io.to("lobby").emit("announcement", "hello")        // from anywhere
```

Server → client with ack: `let reply = try await socket.emitWithAck("question", timeout: 5, payload)`.

Events are handled in order per connection. Handlers are `async`, so a slow handler delays that client's next event (not other clients').

## Writing an adapter

Create `SocketIOServer()`, and for each accepted WebSocket call `server.accept(transport:request:)` with a
`SocketIOTransport` (`send(_:)` / `close()`). Forward incoming text frames to `connection.receive(text:)` and call
`connection.transportDidClose()` when the socket closes. The Vapor adapter is ~100 lines.

## Clients (verified: socket.io-client 4.8.1 and socket.io-client-swift 16.1.1)

Only the WebSocket transport is implemented, so clients must skip HTTP long-polling:

- JS: `io(url, { transports: ["websocket"] })`
- Swift: `SocketManager(socketURL: url, config: [.forceWebsockets(true)])`

## Not supported

HTTP long-polling, binary attachments (binary events are logged and dropped), connection state recovery, and multi-node scaling (no adapter; rooms live in process memory).

## Tests

`swift test` runs protocol and in-memory transport tests. `Tests/Interop/` holds the official JS client, the official
Swift client (`Tests/InteropSwiftClient`) and a ping-timeout check; each adapter package's `Tests/Interop/run.sh`
starts its own example server and runs them against it (needs node).

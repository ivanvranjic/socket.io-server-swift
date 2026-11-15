import Vapor

extension Application {
    /// Entry point for Socket.IO: `app.socketIO.configure()` once at startup, then use `app.socketIO.server` anywhere.
    public var socketIO: SocketIOProvider { SocketIOProvider(application: self) }
}

extension Request {
    /// The server created by `app.socketIO.configure()`. Use it to emit from route handlers.
    public var socketIO: SocketIOServer { application.socketIO.server }
}

public struct SocketIOProvider {
    let application: Application

    private struct Key: StorageKey { typealias Value = SocketIOServer }
    private struct Lifecycle: LifecycleHandler {
        let server: SocketIOServer
        func shutdown(_ application: Application) { server.shutdown() }
    }

    /// Creates the server and mounts it on `configuration.path`. Call once, during `configure(_:)`.
    @discardableResult
    public func configure(_ configuration: SocketIOConfiguration = SocketIOConfiguration()) -> SocketIOServer {
        precondition(application.storage[Key.self] == nil, "Socket.IO is already configured")
        let server = SocketIOServer(application: application, configuration: configuration)
        application.storage[Key.self] = server
        application.lifecycle.use(Lifecycle(server: server))
        server.mount()
        return server
    }

    /// The configured server. Traps if `configure()` hasn't been called.
    public var server: SocketIOServer {
        guard let server = application.storage[Key.self] else {
            fatalError("Socket.IO is not configured. Call app.socketIO.configure() first.")
        }
        return server
    }
}

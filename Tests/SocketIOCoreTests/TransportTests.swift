import NIOConcurrencyHelpers
import XCTest
@testable import SocketIOCore

/// Records what the server sends, so the core can be tested without any web framework.
final class FakeTransport: SocketIOTransport, @unchecked Sendable {
    private let box = NIOLockedValueBox<(sent: [String], closed: Bool)>(([], false))
    var sent: [String] { box.withLockedValue { $0.sent } }
    var closed: Bool { box.withLockedValue { $0.closed } }
    func send(_ text: String) { box.withLockedValue { $0.sent.append(text) } }
    func close() { box.withLockedValue { $0.closed = true } }

    func waitForFrames(_ count: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while sent.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

final class TransportTests: XCTestCase {
    func testHandshakeEventAndAck() async throws {
        let io = SocketIOServer()
        io.onConnection { socket in
            socket.on("sum") { event in
                let a: Int = try event.decode(at: 0), b: Int = try event.decode(at: 1)
                try event.ack?(a + b)
            }
        }
        let transport = FakeTransport()
        let connection = io.accept(transport: transport)

        XCTAssertTrue(transport.sent[0].hasPrefix("0{\"sid\":"), "open packet first")

        connection.receive(text: "40")
        await transport.waitForFrames(2)
        XCTAssertTrue(transport.sent[1].hasPrefix("40{\"sid\":"))

        connection.receive(text: #"427["sum",2,3]"#)
        await transport.waitForFrames(3)
        XCTAssertEqual(transport.sent[2], "437[5]")
        connection.transportDidClose()
    }

    func testBroadcastReachesOtherConnections() async throws {
        let io = SocketIOServer()
        io.onConnection { socket in
            socket.on("hi") { _ in socket.broadcast.emit("hello", "all") }
        }
        let a = FakeTransport(), b = FakeTransport()
        let ca = io.accept(transport: a), cb = io.accept(transport: b)
        ca.receive(text: "40"); cb.receive(text: "40")
        await a.waitForFrames(2); await b.waitForFrames(2)

        ca.receive(text: #"42["hi"]"#)
        await b.waitForFrames(3)
        XCTAssertEqual(b.sent.last, #"42["hello","all"]"#)
        XCTAssertEqual(a.sent.count, 2, "sender must not receive its own broadcast")
        ca.transportDidClose(); cb.transportDidClose()
    }

    func testCloseTransportOnProtocolViolation() async throws {
        let io = SocketIOServer()
        let t = FakeTransport()
        let c = io.accept(transport: t)
        c.receive(text: #"42["x"]"#)  // EVENT before CONNECT
        XCTAssertTrue(t.closed)
    }
}

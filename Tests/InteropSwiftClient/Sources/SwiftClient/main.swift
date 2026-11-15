import Foundation
import SocketIO

// Exercises the Vapor server with the official Swift client (the one the iOS apps would use).

let url = URL(string: CommandLine.arguments.dropFirst().first ?? "http://127.0.0.1:8099")!
let manager = SocketManager(socketURL: url, config: [.forceWebsockets(true), .reconnects(false), .log(false)])
let socket = manager.defaultSocket

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

var step = 0
func advance(_ expected: Int, _ name: String) {
    guard step == expected else { fail("\(name) out of order (step \(step))") }
    step += 1
    print("ok \(name)")
}

socket.on("welcome") { data, _ in
    guard let d = data.first as? [String: Any], d["user"] as? String == "swifty" else { fail("welcome payload \(data)") }
    advance(0, "welcome (auth)")
    socket.emit("echo", ["x": 1, "s": "é"] as [String: Any])
}

socket.on("echo") { data, _ in
    guard let d = data.first as? [String: Any], d["x"] as? Int == 1, d["s"] as? String == "é" else { fail("echo \(data)") }
    advance(1, "echo")
    socket.emitWithAck("sum", 2, 3).timingOut(after: 3) { result in
        guard result.first as? Int == 5 else { fail("ack \(result)") }
        advance(2, "client->server ack")
        socket.emit("ask")
    }
}

socket.on("question") { data, ack in
    guard data.first as? String == "ping" else { fail("question \(data)") }
    ack.with("answer:ping")
}

socket.on("asked") { data, _ in
    guard data.first as? String == "answer:ping" else { fail("asked \(data)") }
    advance(3, "server->client ack")
    socket.emit("kick")
}

socket.on(clientEvent: .disconnect) { _, _ in
    advance(4, "server disconnect")
    print("swift client OK")
    exit(0)
}

socket.on(clientEvent: .error) { data, _ in fail("socket error \(data)") }

socket.connect(withPayload: ["token": "swifty"])

DispatchQueue.main.asyncAfter(deadline: .now() + 10) { fail("timeout at step \(step)") }
RunLoop.main.run()

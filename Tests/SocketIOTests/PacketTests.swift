import XCTest
@testable import SocketIO

final class PacketTests: XCTestCase {
    func testDecodeDefaultNamespaceEvent() {
        let p = Packet.decode(#"2["hello",{"a":1}]"#)
        XCTAssertEqual(p, Packet(type: .event, namespace: "/", id: nil, payload: #"["hello",{"a":1}]"#))
    }

    func testDecodeNamespaceWithAckId() {
        let p = Packet.decode(#"2/admin,12["hi"]"#)
        XCTAssertEqual(p, Packet(type: .event, namespace: "/admin", id: 12, payload: #"["hi"]"#))
    }

    func testDecodeConnectWithAuth() {
        let p = Packet.decode(#"0{"token":"abc"}"#)
        XCTAssertEqual(p?.type, .connect)
        XCTAssertEqual(p?.payload, #"{"token":"abc"}"#)
    }

    func testDecodeConnectNamespaceWithoutComma() {
        XCTAssertEqual(Packet.decode("0/admin"), Packet(type: .connect, namespace: "/admin"))
    }

    func testDecodeAck() {
        XCTAssertEqual(Packet.decode(#"3/chat,5["ok"]"#), Packet(type: .ack, namespace: "/chat", id: 5, payload: #"["ok"]"#))
    }

    func testRejectsGarbage() {
        XCTAssertNil(Packet.decode(""))
        XCTAssertNil(Packet.decode("x"))
        XCTAssertNil(Packet.decode("9[]"))
    }

    func testEncodeRoundTrip() {
        for packet in [
            Packet(type: .event, namespace: "/", id: nil, payload: #"["a",1]"#),
            Packet(type: .event, namespace: "/room", id: 3, payload: #"["a"]"#),
            Packet(type: .ack, namespace: "/", id: 0, payload: "[]"),
            Packet(type: .connect, namespace: "/x", payload: #"{"sid":"1"}"#),
            Packet(type: .disconnect, namespace: "/x"),
        ] {
            XCTAssertEqual(Packet.decode(packet.encoded()), packet, packet.encoded())
        }
    }

    func testJSONValueRoundTrip() throws {
        struct Msg: Codable, Equatable { let text: String; let n: Int }
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"text":"hi","n":3,"list":[1,2.5,null,true]}"#.utf8))
        XCTAssertEqual(v["text"]?.stringValue, "hi")
        XCTAssertEqual(v["n"]?.intValue, 3)
        XCTAssertEqual(try v.decode(Msg.self, using: JSONDecoder()).n, 3)
        XCTAssertEqual(try JSONValue.string("x").decode(String.self), "x")
    }
}

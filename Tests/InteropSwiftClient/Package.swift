// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "InteropSwiftClient",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftClient",
            dependencies: [.product(name: "SocketIO", package: "socket.io-client-swift")]
        ),
    ]
)

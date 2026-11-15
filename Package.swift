// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "socket.io-server-swift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SocketIOCore", targets: ["SocketIOCore"]),
        .library(name: "SocketIOVapor", targets: ["SocketIOVapor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Transport-agnostic Socket.IO server. No Vapor dependency.
        .target(
            name: "SocketIOCore",
            dependencies: [
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Vapor adapter: mounts the endpoint on a Vapor app's WebSocket router.
        .target(
            name: "SocketIOVapor",
            dependencies: [
                .target(name: "SocketIOCore"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .executableTarget(
            name: "InteropServer",
            dependencies: [
                .target(name: "SocketIOVapor"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Examples/InteropServer"
        ),
        .testTarget(
            name: "SocketIOCoreTests",
            dependencies: [
                .target(name: "SocketIOCore"),
            ]
        ),
    ]
)

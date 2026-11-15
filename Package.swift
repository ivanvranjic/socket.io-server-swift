// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "vapor-socketio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SocketIO", targets: ["SocketIO"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "SocketIO",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "InteropServer",
            dependencies: [
                .target(name: "SocketIO"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Examples/InteropServer"
        ),
        .testTarget(
            name: "SocketIOTests",
            dependencies: [
                .target(name: "SocketIO"),
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ASUSRouterBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RouterBar", targets: ["RouterBar"])],
    targets: [
        .target(name: "RouterCore", resources: [.process("Resources")]),
        .executableTarget(name: "RouterBar", dependencies: ["RouterCore"]),
        .testTarget(name: "RouterCoreTests", dependencies: ["RouterCore"])
    ]
)

// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PWebDAV",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PWebDAV", targets: ["PWebDAV"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0")
    ],
    targets: [
        .executableTarget(
            name: "PWebDAV",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)

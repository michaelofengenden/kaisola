// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KaisolaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "KaisolaCore", targets: ["KaisolaCore"]),
        .library(name: "KaisolaBrokerProtocol", targets: ["KaisolaBrokerProtocol"]),
        .library(name: "KaisolaTestSupport", targets: ["KaisolaTestSupport"]),
    ],
    targets: [
        .target(name: "KaisolaCore"),
        .target(
            name: "KaisolaBrokerProtocol",
            dependencies: ["KaisolaCore"]
        ),
        .target(
            name: "KaisolaTestSupport",
            dependencies: ["KaisolaCore", "KaisolaBrokerProtocol"]
        ),
        .testTarget(
            name: "KaisolaCoreTests",
            dependencies: ["KaisolaCore", "KaisolaTestSupport"]
        ),
        .testTarget(
            name: "KaisolaBrokerProtocolTests",
            dependencies: ["KaisolaBrokerProtocol", "KaisolaTestSupport"]
        ),
    ]
)

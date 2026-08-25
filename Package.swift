// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "TelemetryHub",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TelemetryHub", targets: ["TelemetryHub"]),
        .library(name: "TelemetryHubNIO", targets: ["TelemetryHubNIO"]),
        .library(name: "TelemetryHubGRPC", targets: ["TelemetryHubGRPC"]),
        .library(name: "TelemetryHubLiveKit", targets: ["TelemetryHubLiveKit"]),
        .library(name: "TelemetryHubSRT", targets: ["TelemetryHubSRT"]),
        .library(name: "TelemetryHubSentry", targets: ["TelemetryHubSentry"]),
        .library(name: "TelemetryHubUI", targets: ["TelemetryHubUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.2"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.16.0"),
        .package(path: "../SRTKit"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.26.0"),
    ],
    targets: [
        .target(
            name: "TelemetryHub"
        ),
        .target(
            name: "TelemetryHubNIO",
            dependencies: [
                "TelemetryHub",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .target(
            name: "TelemetryHubGRPC",
            dependencies: [
                "TelemetryHub",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
            ]
        ),
        .target(
            name: "TelemetryHubLiveKit",
            dependencies: [
                "TelemetryHub",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
        .target(
            name: "TelemetryHubSRT",
            dependencies: [
                "TelemetryHub",
                .product(name: "SRTCore", package: "SRTKit"),
            ]
        ),
        .target(
            name: "TelemetryHubSentry",
            dependencies: [
                "TelemetryHub",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "TelemetryHubUI",
            dependencies: ["TelemetryHub"]
        ),
        .testTarget(
            name: "TelemetryHubTests",
            dependencies: ["TelemetryHub"]
        ),
        .testTarget(
            name: "TelemetryHubGRPCTests",
            dependencies: [
                "TelemetryHub",
                "TelemetryHubGRPC",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

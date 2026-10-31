// swift-tools-version: 6.0
import PackageDescription

// Layering rule: a target may only depend on targets in its own layer or below.
//   0 Foundation  → TenderCore, TenderProtocol
//   1 Platform    → LaunchdKit, ProcessMetrics, FileWatch, LogTail   (no networking)
//   2 Features    → TenderActorSystem, TenderAgent, TenderLogStore, TenderPKI, TenderScheduler,
//                   TenderMetrics, TenderMCP, TenderClient, TenderHead
//   3 Executables → tenderd, tender
//
// Hummingbird and AsyncHTTPClient carry the local HTTP/JSON API (Unix socket).
// Other networking deps (swift-nio-ssl, MCP swift-sdk, swift-prometheus) are
// added in milestone 2. Head<->worker traffic uses Swift
// distributed actors over our own TenderActorSystem (no grpc-swift).

let package = Package(
    name: "TenderKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tenderd", targets: ["tenderd"]),
        .executable(name: "tender", targets: ["tender"]),
        // Libraries consumed by TenderApp (menu bar + dashboard).
        .library(name: "TenderClient", targets: ["TenderClient"]),
        .library(name: "TenderCore", targets: ["TenderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        // MARK: 0 — Foundation
        .target(name: "TenderCore"),
        .target(name: "TenderProtocol", dependencies: ["TenderCore"]),

        // MARK: 1 — macOS platform (no networking)
        .target(name: "LaunchdKit", dependencies: [
            "TenderCore",
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "ProcessMetrics", dependencies: ["TenderCore"]),
        .target(name: "FileWatch", dependencies: [
            "TenderCore",
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "LogTail", dependencies: [
            "TenderCore",
            .product(name: "Logging", package: "swift-log"),
        ]),

        // MARK: 2 — Features
        .target(name: "TenderActorSystem", dependencies: [
            "TenderCore",
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "TenderAgent", dependencies: [
            "TenderCore", "TenderProtocol", "TenderActorSystem", "LaunchdKit", "ProcessMetrics", "FileWatch", "LogTail",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "UnixSignals", package: "swift-service-lifecycle"),
        ]),
        .target(name: "TenderLogStore", dependencies: [
            "TenderCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "TenderPKI", dependencies: ["TenderCore"]),
        .target(name: "TenderScheduler", dependencies: ["TenderCore"]),
        .target(name: "TenderMetrics", dependencies: ["TenderCore"]),
        .target(name: "TenderClient", dependencies: [
            "TenderCore", "TenderProtocol",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .target(name: "TenderMCP", dependencies: ["TenderCore", "TenderClient"]),
        .target(name: "TenderHead", dependencies: [
            "TenderCore", "TenderProtocol", "TenderActorSystem", "TenderLogStore", "TenderPKI",
            "TenderScheduler", "TenderMetrics", "TenderMCP",
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),

        // MARK: 3 — Executables (thin: parse args, wire, run)
        .executableTarget(name: "tenderd", dependencies: [
            "TenderCore", "TenderAgent", "TenderHead",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "tender", dependencies: [
            "TenderCore", "TenderClient", "LaunchdKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),

        // MARK: Tests
        .testTarget(name: "ProcessMetricsTests", dependencies: ["ProcessMetrics"]),
        .testTarget(name: "LogTailTests", dependencies: ["LogTail", "LaunchdKit"]),
        .testTarget(name: "TenderCoreTests", dependencies: ["TenderCore"]),
        .testTarget(name: "TenderAgentTests", dependencies: [
            "TenderAgent", "TenderClient", "TenderCore", "LaunchdKit", "LogTail",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "LaunchdKitTests", dependencies: ["LaunchdKit"], resources: [.copy("Fixtures")]),
    ]
)

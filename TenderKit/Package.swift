// swift-tools-version: 6.0
import PackageDescription

// Layering rule: a target may only depend on targets in its own layer or below.
//   0 Foundation  → TenderCore, TenderProtocol
//   1 Platform    → LaunchdKit, ProcessMetrics, FileWatch, LogTail   (no networking)
//   2 Features    → TenderActorSystem, TenderAgent, TenderLogStore, TenderPKI, TenderScheduler,
//                   TenderMetrics, TenderClient, TenderHead
//   3 Executables → tenderd, tender
//
// TenderApp is a separate Xcode project (App/) on top of this package. It imports only TenderClient and TenderCore.
//
// Hummingbird and AsyncHTTPClient carry the local HTTP/JSON API (Unix socket).
// swift-nio-ssl carries mTLS. Head<->worker traffic uses Swift
// distributed actors over our own TenderActorSystem (no grpc-swift).

let package = Package(
    name: "TenderKit",
    platforms: [.macOS(.v15)],
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
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        // Service files. TenderClient only: the app and the daemons never parse YAML.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
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
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "X509", package: "swift-certificates"),
        ]),
        .target(name: "TenderAgent", dependencies: [
            "TenderCore", "TenderProtocol", "TenderActorSystem", "TenderPKI", "LaunchdKit", "ProcessMetrics", "FileWatch", "LogTail",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "UnixSignals", package: "swift-service-lifecycle"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .target(name: "TenderLogStore", dependencies: [
            "TenderCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "TenderPKI", dependencies: [
            "TenderCore",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
        ]),
        .target(name: "TenderScheduler", dependencies: ["TenderCore"]),
        .target(name: "TenderMetrics", dependencies: ["TenderCore"]),
        .target(name: "TenderClient", dependencies: [
            "TenderCore", "TenderProtocol",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "Yams", package: "Yams"),
        ]),
        .target(name: "TenderHead", dependencies: [
            "TenderCore", "TenderProtocol", "TenderActorSystem", "TenderAgent", "TenderLogStore", "TenderPKI",
            "TenderScheduler", "TenderMetrics",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTLS", package: "hummingbird"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),

        // MARK: 3 — Executables (thin: parse args, wire, run)
        .executableTarget(name: "tenderd", dependencies: [
            "TenderCore", "TenderAgent", "TenderHead", "TenderPKI",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "tender", dependencies: [
            "TenderCore", "TenderClient", "LaunchdKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),

        // MARK: Tests
        .testTarget(name: "TenderTransportTests", dependencies: [
            "TenderActorSystem", "TenderProtocol", "TenderPKI", "TenderCore",
        ]),
        .testTarget(name: "TenderHeadTests", dependencies: [
            "TenderHead", "TenderAgent", "TenderClient", "TenderCore", "TenderPKI", "TenderActorSystem", "TenderProtocol", "LaunchdKit", "TenderLogStore",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "TenderLogStoreTests", dependencies: ["TenderLogStore", "TenderCore"]),
        .testTarget(name: "TenderMetricsTests", dependencies: ["TenderMetrics", "TenderCore"]),
        .testTarget(name: "TenderPKITests", dependencies: [
            "TenderPKI", "TenderCore",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
        ]),
        .testTarget(name: "ProcessMetricsTests", dependencies: ["ProcessMetrics"]),
        .testTarget(name: "LogTailTests", dependencies: ["LogTail", "LaunchdKit"]),
        .testTarget(name: "TenderCoreTests", dependencies: ["TenderCore"]),
        .testTarget(name: "TenderClientTests", dependencies: ["TenderClient", "TenderCore"]),
        .testTarget(name: "TenderAgentTests", dependencies: [
            "TenderAgent", "TenderClient", "TenderCore", "LaunchdKit", "LogTail", "FileWatch",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "LaunchdKitTests", dependencies: ["LaunchdKit"], resources: [.copy("Fixtures")]),
    ]
)

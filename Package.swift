// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-ddd-kit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DDDKit",
            targets: ["DDDKit"]),
        .library(
            name: "ContextForwarder",
            targets: ["ContextForwarder"]),
        .library(
            name: "PublishedLanguage",
            targets: ["PublishedLanguage"]),
        .library(
            name: "ContextReceiver",
            targets: ["ContextReceiver"]),
        .library(
            name: "ContextReceiverWebSocket",
            targets: ["ContextReceiverWebSocket"]),
        .library(
            name: "TestUtility",
            targets: ["TestUtility"]),
        .library(
            name: "MigrationUtility",
            targets: ["MigrationUtility"]),
        .library(
            name: "ReadModelPersistence",
            targets: ["ReadModelPersistence"]),
        .library(
            name: "ReadModelPersistencePostgres",
            targets: ["ReadModelPersistencePostgres"]),
        .library(
            name: "PostgresSupport",
            targets: ["PostgresSupport"]),
        .library(
            name: "KurrentSupportInMemory",
            targets: ["KurrentSupportInMemory"]),
        .library(
            name: "DomainEventGenerator",
            targets: ["DomainEventGenerator"]),
       .plugin(name: "DomainEventGeneratorPlugin", targets: [
           "DomainEventGeneratorPlugin"
       ]),
       .plugin(name: "ModelGeneratorPlugin", targets: [
           "ModelGeneratorPlugin"
       ]),
       .plugin(name: "GenerateKurrentDBProjectionsPlugin", targets: [
           "GenerateKurrentDBProjectionsPlugin"
       ]),
    ],
    dependencies: [
        .package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.3.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0"),
        // Floor matches async-http-client's own declared floor (2.81.0); already
        // resolved to 2.97.0 transitively, so this adds no new version constraint.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.4"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        // Pinned to upstream. Does not build on the macOS 26 SDK (missing @available
        // on ByteBuffer.init(_uint8Span:)); Linux is verified clean on Swift 6.2.4.
        // This is why the WebSocket transport is its own target — every other target
        // and all unit tests stay buildable on macOS.
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.1"),
        // HTTPFields carries the Authorization header into WebSocketClientConfiguration.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DDDKit", dependencies: [
                "DDDCore",
                "EventSourcing",
                "KurrentSupport",
                "EventBus",
                "ReadModelPersistence",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]),
        .target(
            name: "DDDCore"),
        .target(
            name: "EventSourcing",
            dependencies: [
                "DDDCore",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .target(
            name: "KurrentSupport",
            dependencies: [
                "DDDCore",
                "EventSourcing",
                .product(name: "KurrentDB", package: "swift-kurrentdb")
            ]),
        .target(
            name: "EventBus",
            dependencies: [
                "DDDCore",
            ]),
        .target(
            name: "TestUtility",
            dependencies: [
                "DDDCore",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
                .product(name: "KurrentDBPool", package: "swift-kurrentdb"),
            ]),
        .target(
            name: "ReadModelPersistence",
            dependencies: [
                "DDDCore",
                "EventSourcing",
            ]),
        .target(
            name: "ReadModelPersistencePostgres",
            dependencies: [
                "ReadModelPersistence",
                "EventSourcing",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]),
        .target(
            name: "PostgresSupport",
            dependencies: [
                "ReadModelPersistencePostgres",
                "KurrentSupport",
                "EventSourcing",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .target(
            name: "KurrentSupportInMemory",
            dependencies: [
                "KurrentSupport",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
            ]),
        .testTarget(
            name: "KurrentSupportInMemoryTests",
            dependencies: [
                "KurrentSupportInMemory",
                "KurrentSupport",
                "EventSourcing",
                "ReadModelPersistence",
                "DDDCore",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
            ]),
        .testTarget(
            name: "ReadModelPersistencePostgresIntegrationTests",
            dependencies: [
                "ReadModelPersistencePostgres",
                "ReadModelPersistence",
                "EventSourcing",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]),
        .testTarget(
            name: "KurrentSupportUnitTests",
            dependencies: [
                "KurrentSupport",
                "EventSourcing",
                "ReadModelPersistence",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
            ]),
        .testTarget(
            name: "KurrentSupportIntegrationTests",
            dependencies: [
                "KurrentSupport",
                "EventSourcing",
                "ReadModelPersistence",
                "ReadModelPersistencePostgres",
                "PostgresSupport",
                "DDDCore",
                "TestUtility",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .target(name: "MigrationUtility",
                dependencies: [
                    "DDDCore",
                    "KurrentSupport",
                    .product(name: "KurrentDB", package: "swift-kurrentdb")
                ]),
        .testTarget(
            name: "DDDCoreTests",
            dependencies: ["DDDKit", "TestUtility"]
        ),
        .testTarget(
            name: "EventSourcingTests",
            dependencies: ["DDDKit", "EventSourcing", "TestUtility"]
        ),
        .testTarget(
            name: "DDDKitUnitTests",
            dependencies: ["DDDCore", "EventSourcing", "EventBus"]
        ),
        .testTarget(
            name: "ReadModelPersistenceTests",
            dependencies: ["ReadModelPersistence", "DDDCore", "EventSourcing"]
        ),
        .testTarget(
            name: "DomainEventGeneratorTests",
            dependencies: [
                "DomainEventGenerator",
                .product(name: "Yams", package: "yams"),
            ]),
        .target(name: "DomainEventGenerator",
                dependencies: [
                    .product(name: "Yams", package: "yams")
                ]),
        .target(
            name: "PublishedLanguage"),
        .target(
            name: "ContextForwarder",
            dependencies: [
                "PublishedLanguage",
                .product(name: "KurrentDB", package: "swift-kurrentdb"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources/ContextForwarder"
        ),
        .testTarget(
            name: "ContextForwarderTests",
            dependencies: ["ContextForwarder", "PublishedLanguage"],
            path: "Tests/ContextForwarderTests"
        ),
        .testTarget(
            name: "ContextForwarderIntegrationTests",
            dependencies: ["ContextForwarder", "PublishedLanguage"],
            path: "Tests/ContextForwarderIntegrationTests"
        ),
        .target(
            name: "ContextReceiver",
            dependencies: [
                "PublishedLanguage",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources/ContextReceiver"
        ),
        .testTarget(
            name: "ContextReceiverTests",
            dependencies: [
                "ContextReceiver", "PublishedLanguage",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/ContextReceiverTests"
        ),
        .target(
            name: "ContextReceiverWebSocket",
            dependencies: [
                "ContextReceiver",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                // Platform-conditional so macOS never compiles swift-websocket (or its
                // HTTPTypes header type) at all. Without the condition, `swift build`
                // on macOS fails for the whole package — including for
                // OpportunityContext developers who never touch the receiver.
                .product(name: "WSClient", package: "swift-websocket", condition: .when(platforms: [.linux])),
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/ContextReceiverWebSocket"
        ),
        .executableTarget(name: "generate",
                          dependencies: [
                            "DomainEventGenerator",
                            .product(name: "ArgumentParser", package: "swift-argument-parser")
                          ]),
        .plugin(
          name: "DomainEventGeneratorPlugin",
          capability: .buildTool(),
          dependencies: [
            "generate"
          ]),
        .plugin(
          name: "PresenterCommandPlugin",
          capability: .command(
            intent: .custom(
                verb: "generate-presenter",
                description: "generate-presenter"),
            permissions: [
                PluginPermission.writeToPackageDirectory(
                    reason: "it will generate projection swift files.")]),
          dependencies: [
            "generate",
          ]),
        .plugin(
          name: "ModelGeneratorPlugin",
          capability: .buildTool(),
          dependencies: [
            "generate"
          ]),
        .plugin(
          name: "GenerateKurrentDBProjectionsPlugin",
          capability: .command(
            intent: .custom(
                verb: "generate-kurrentdb-projections",
                description: "Generate KurrentDB .js projection files from projection-model.yaml"),
            permissions: [
                PluginPermission.writeToPackageDirectory(
                    reason: "Writes generated KurrentDB projection .js files to the projections/ directory.")
            ]),
          dependencies: [
            "generate",
          ]),
    ]
)

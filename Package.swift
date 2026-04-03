// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-ddd-kit",
    platforms: [
        .macOS(.v15),
        .iOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DDDKit",
            targets: ["DDDKit"]),
        .library(
            name: "TestUtility",
            targets: ["TestUtility"]),
        .library(
            name: "MigrationUtility",
            targets: ["MigrationUtility"]),
        .library(
            name: "ReadModelPersistence",
            targets: ["ReadModelPersistence"]),
        .library(name: "ReadModelPersistencePostgres", targets: ["ReadModelPersistencePostgres"]),
        .library(
            name: "DomainEventGenerator",
            targets: ["DomainEventGenerator"]),
       .plugin(name: "DomainEventGeneratorPlugin", targets: [
           "DomainEventGeneratorPlugin"
       ]),
       .plugin(name: "ModelGeneratorPlugin", targets: [
           "ModelGeneratorPlugin"
       ])
    ],
    dependencies: [
        .package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.4"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
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
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]),
        .testTarget(
            name: "ReadModelPersistencePostgresIntegrationTests",
            dependencies: [
                "ReadModelPersistencePostgres",
                "ReadModelPersistence",
                .product(name: "PostgresNIO", package: "postgres-nio"),
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
        .target(name: "DomainEventGenerator",
                dependencies: [
                    .product(name: "Yams", package: "yams")
                ]),
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
        
    ]
)

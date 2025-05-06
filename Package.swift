// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DDDKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DDDKit",
            targets: ["DDDKit"]
        ),
        .library(
            name: "TestUtility",
            targets: ["TestUtility"]
        ),
        .library(
            name: "DomainEventGenerator",
            targets: ["DomainEventGenerator"]
        ),
       .plugin(name: "DomainEventGeneratorPlugin", targets: [
           "DomainEventGeneratorPlugin"
           
       ]),
       .plugin(name: "ProjectionModelGeneratorPlugin", targets: [
           "ProjectionModelGeneratorPlugin"
       ])
    ],
    dependencies: [
    .package(url: "https://github.com/gradyzhuo/KurrentDB-Swift.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
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
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "DDDCore"),
        .target(
            name: "EventSourcing",
            dependencies: [
                "DDDCore",
            ]
        ),
        .target(
            name: "KurrentSupport",
            dependencies: [
                "DDDCore",
                "EventSourcing",
                .product(name: "EventStoreDB", package: "kurrentdb-swift")
            ]
        ),
        .target(
            name: "EventBus",
            dependencies: [
                "DDDCore",
            ]
        ),
        .target(
            name: "TestUtility",
            dependencies: [
                "DDDCore",
                .product(name: "EventStoreDB", package: "kurrentdb-swift"),
            ]
        ),
        .testTarget(
            name: "DDDCoreTests",
            dependencies: ["DDDKit", "TestUtility"]
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
          name: "ProjectionModelGeneratorPlugin",
          capability: .buildTool(),
          dependencies: [
            "generate"
          ]),
        
    ],
    swiftLanguageModes: [
        .v5
    ]
)

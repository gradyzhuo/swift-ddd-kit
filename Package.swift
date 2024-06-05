// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DDDKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DDDCore",
            targets: ["DDDCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/gradyzhuo/EventStoreDB-Swift.git", from: "0.2.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DDDCore"),
        .target(
            name: "CQRS",
            dependencies: [
                "DDDCore",
            ]
        ),
        .target(
            name: "EventSourcing",
            dependencies: [
                "DDDCore",
                .product(name: "EventStoreDB", package: "eventstoredb-swift")
            ]
        ),
        .testTarget(
            name: "DDDCoreTests",
            dependencies: ["DDDCore", "EventSourcing",
                .product(name: "EventStoreDB", package: "eventstoredb-swift")
            ]
        ),
    ]
)

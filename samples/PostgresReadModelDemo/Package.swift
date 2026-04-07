// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PostgresReadModelDemo",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "PostgresReadModelDemo",
            dependencies: [
                .product(name: "DDDKit", package: "swift-ddd-kit"),
                .product(name: "ReadModelPersistence", package: "swift-ddd-kit"),
                .product(name: "ReadModelPersistencePostgres", package: "swift-ddd-kit"),
            ],
            path: "Sources",
            plugins: [
                .plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit"),
                .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
            ]
        ),
    ]
)

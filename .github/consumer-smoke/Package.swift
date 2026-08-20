// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerunMigrationsConsumerSmoke",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MigrationConsumerSmoke",
            dependencies: [
                .product(name: "PerunDBAL", package: "perun-orm"),
                .product(name: "PerunDBALSQLite", package: "perun-orm"),
                .product(name: "PerunMigrations", package: "perun-orm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

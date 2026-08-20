// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerunORM",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PerunDBAL", targets: ["PerunDBAL"]),
        .library(name: "PerunDBALPostgres", targets: ["PerunDBALPostgres"]),
        .library(name: "PerunDBALSQLite", targets: ["PerunDBALSQLite"]),
        .library(name: "PerunMigrations", targets: ["PerunMigrations"]),
        .library(name: "PerunORM", targets: ["PerunORM"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/tavvet/perun-pgsql.git",
            .upToNextMinor(from: "0.3.0")
        ),
        .package(
            url: "https://github.com/tavvet/perun-sqlite.git",
            .upToNextMinor(from: "0.2.0")
        ),
    ],
    targets: [
        .target(name: "PerunDBAL"),
        .target(
            name: "PerunDBALPostgres",
            dependencies: [
                "PerunDBAL",
                .product(name: "PerunPGSQL", package: "perun-pgsql"),
            ]
        ),
        .target(
            name: "PerunDBALSQLite",
            dependencies: [
                "PerunDBAL",
                .product(name: "PerunSQLite", package: "perun-sqlite"),
            ]
        ),
        .target(
            name: "PerunMigrations",
            dependencies: ["PerunDBAL"]
        ),
        .target(
            name: "PerunORM",
            dependencies: ["PerunDBAL"]
        ),
        .testTarget(
            name: "PerunDBALTests",
            dependencies: [
                "PerunDBAL",
                "PerunDBALPostgres",
                "PerunDBALSQLite",
                .product(name: "PerunPGSQL", package: "perun-pgsql"),
                .product(name: "PerunSQLite", package: "perun-sqlite"),
            ]
        ),
        .testTarget(
            name: "PerunMigrationsTests",
            dependencies: [
                "PerunDBAL",
                "PerunDBALPostgres",
                "PerunDBALSQLite",
                "PerunMigrations",
                .product(name: "PerunPGSQL", package: "perun-pgsql"),
                .product(name: "PerunSQLite", package: "perun-sqlite"),
            ]
        ),
        .testTarget(
            name: "PerunORMTests",
            dependencies: [
                "PerunDBAL",
                "PerunDBALPostgres",
                "PerunDBALSQLite",
                "PerunORM",
                .product(name: "PerunPGSQL", package: "perun-pgsql"),
                .product(name: "PerunSQLite", package: "perun-sqlite"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

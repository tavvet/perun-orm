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
        .library(name: "PerunORM", targets: ["PerunORM"]),
    ],
    dependencies: [
        .package(path: "../perun-sqlite"),
    ],
    targets: [
        .target(name: "PerunDBAL"),
        .target(
            name: "PerunDBALPostgres",
            dependencies: ["PerunDBAL"]
        ),
        .target(
            name: "PerunDBALSQLite",
            dependencies: [
                "PerunDBAL",
                .product(name: "PerunSQLite", package: "perun-sqlite"),
            ]
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
                .product(name: "PerunSQLite", package: "perun-sqlite"),
            ]
        ),
        .testTarget(
            name: "PerunORMTests",
            dependencies: ["PerunDBAL", "PerunORM"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

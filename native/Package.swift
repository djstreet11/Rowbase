// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Rowbase",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rowbase", targets: ["Rowbase"]),
        .library(name: "RowbaseCore", targets: ["RowbaseCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
    ],
    targets: [
        .target(name: "RowbaseCore", dependencies: [
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "MySQLNIO", package: "mysql-nio"),
        ], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Rowbase", dependencies: ["RowbaseCore"]),
        .testTarget(name: "RowbaseCoreTests", dependencies: ["RowbaseCore"]),
    ]
)

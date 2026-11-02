// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemanenceCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RemanenceCore", targets: ["RemanenceCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0")
    ],
    targets: [
        .target(
            name: "RemanenceCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "RemanenceCoreTests",
            dependencies: ["RemanenceCore"]
        ),
    ]
)

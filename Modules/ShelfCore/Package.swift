// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShelfCore", targets: ["ShelfCore"])
    ],
    targets: [
        .target(name: "ShelfCore"),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"])
    ]
)

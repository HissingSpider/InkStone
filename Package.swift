// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inkstone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InkstoneCore", targets: ["InkstoneCore"]),
        .executable(name: "inkstone", targets: ["inkstone"]),
        .executable(name: "InkstoneMenuBar", targets: ["InkstoneMenuBar"]),
    ],
    targets: [
        .target(
            name: "InkstoneCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "inkstone", dependencies: ["InkstoneCore"]),
        .executableTarget(name: "InkstoneMenuBar", dependencies: ["InkstoneCore"]),
        .testTarget(name: "InkstoneCoreTests", dependencies: ["InkstoneCore"]),
    ]
)

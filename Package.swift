// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VisDiff",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VisDiff", targets: ["VisDiff"]),
    ],
    targets: [
        .target(name: "DiffCore"),
        .executableTarget(name: "VisDiff", dependencies: ["DiffCore"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Twofold",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Twofold", targets: ["Twofold"]),
    ],
    targets: [
        .target(name: "DiffCore"),
        .executableTarget(name: "Twofold", dependencies: ["DiffCore"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
    ]
)

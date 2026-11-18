// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Qingzhou",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Qingzhou", targets: ["Qingzhou"])],
    targets: [
        .target(name: "CleanCore"),
        .executableTarget(name: "Qingzhou", dependencies: ["CleanCore"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"])
    ]
)

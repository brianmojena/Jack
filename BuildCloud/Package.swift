// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuildCloud",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BuildCloudCore", targets: ["BuildCloudCore"]),
        .executable(name: "BuildCloudApp", targets: ["BuildCloudApp"]),
        .executable(name: "buildcloud", targets: ["BuildCloudCLI"])
    ],
    targets: [
        .target(name: "BuildCloudCore"),
        .executableTarget(name: "BuildCloudApp", dependencies: ["BuildCloudCore"]),
        .executableTarget(name: "BuildCloudCLI", dependencies: ["BuildCloudCore"]),
        .testTarget(name: "BuildCloudCoreTests", dependencies: ["BuildCloudCore"])
    ],
    swiftLanguageModes: [.v5]
)

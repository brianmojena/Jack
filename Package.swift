// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jack",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JackCore", targets: ["JackCore"]),
        .executable(name: "Jack", targets: ["Jack"]),
        .executable(name: "JackProbe", targets: ["JackProbe"]),
        .executable(name: "JackChatProbe", targets: ["JackChatProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0")
    ],
    targets: [
        .target(name: "JackCore"),
        .executableTarget(name: "Jack", dependencies: ["JackCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "JackProbe", dependencies: ["JackCore"]),
        .executableTarget(name: "JackChatProbe", dependencies: ["JackCore"]),
        .testTarget(name: "JackCoreTests", dependencies: ["JackCore"])
    ],
    swiftLanguageVersions: [.v5]
)

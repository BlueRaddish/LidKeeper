// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LidKeeper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LidKeeper", targets: ["LidKeeper"])],
    targets: [
        .target(name: "SessionPolicy"),
        .executableTarget(name: "LidKeeper", dependencies: ["SessionPolicy"]),
        .executableTarget(name: "PolicyChecks", dependencies: ["SessionPolicy"], path: "Tests/PolicyChecks")
    ]
)

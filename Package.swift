// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LogcatMini",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LogcatMini", targets: ["LogcatMini"])],
    targets: [
        .target(name: "LogcatCore"),
        .executableTarget(name: "LogcatMini", dependencies: ["LogcatCore"], resources: [.copy("Resources/AppMetadata.jar"), .copy("Resources/Recording")]),
        .testTarget(name: "LogcatCoreTests", dependencies: ["LogcatCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LogcatMiniTests", dependencies: ["LogcatMini", "LogcatCore"])
    ]
)

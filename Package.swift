// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LogcatMini",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LogcatMini", targets: ["LogcatMini"]),
               .executable(name: "IOSSimulatorBridge", targets: ["IOSSimulatorBridge"])],
    targets: [
        .target(name: "LogcatCore"),
        .target(name: "WindowsAppCards"),
        .executableTarget(name: "BastionConnector", dependencies: ["WindowsAppCards"]),
        .executableTarget(name: "IOSSimulatorBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreImage"), .linkedFramework("IOSurface")]),
        .executableTarget(name: "LogcatMini", dependencies: ["LogcatCore", "WindowsAppCards"], resources: [.copy("Resources/AppMetadata.jar"), .copy("Resources/DeviceInfo.apk"), .copy("Resources/Recording"), .copy("Resources/IOSDeviceInfoHelper")]),
        .testTarget(name: "LogcatCoreTests", dependencies: ["LogcatCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LogcatMiniTests", dependencies: ["LogcatMini", "LogcatCore"])
    ]
)

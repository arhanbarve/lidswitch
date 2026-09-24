// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "lidswitch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LidswitchCore"),
        .executableTarget(
            name: "Lidswitch",
            dependencies: ["LidswitchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
        .testTarget(name: "LidswitchCoreTests", dependencies: ["LidswitchCore"]),
    ]
)

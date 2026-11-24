// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "xcode-agent-bridge",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "XcodeAgentBridge", targets: ["XcodeAgentBridge"]),
    ],
    targets: [
        // Pure logic: selections, prompts, command lines and agent output parsing.
        .target(name: "BridgeCore"),
        // The menu bar app: Accessibility capture, global hot key and the floating panel.
        .executableTarget(
            name: "XcodeAgentBridge",
            dependencies: ["BridgeCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)

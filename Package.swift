// swift-tools-version:5.10
// Agent Load: macOS menu bar app showing machine load per OpenChamber/opencode session.
// Swift 5 language mode on purpose: AppKit + libproc interop under Swift 6 strict
// concurrency adds a lot of noise for a tiny single-process app.
import PackageDescription

let package = Package(
    name: "AgentLoad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentLoad", targets: ["AgentLoad"]),
    ],
    targets: [
        // Pure logic + system readers (libproc, sysctl, sqlite). No UI.
        .target(
            name: "AgentLoadCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu bar app itself (AppKit status item + SwiftUI views), plus --dump / --render-png.
        .executableTarget(
            name: "AgentLoad",
            dependencies: ["AgentLoadCore"]
        ),
        // Swift Testing tests. Run with scripts/test.sh (Command Line Tools need extra framework flags).
        .testTarget(
            name: "AgentLoadCoreTests",
            dependencies: ["AgentLoadCore"]
        ),
    ]
)

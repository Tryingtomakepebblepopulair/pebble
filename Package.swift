// swift-tools-version: 6.0
// Pebble — a native Swift + Metal block-survival game for macOS.
// CLI-only workflow: swift build -c release. No .xcodeproj.

import PackageDescription

let package = Package(
    name: "Pebble",
    platforms: [.macOS(.v14)],
    targets: [
        // the portable deterministic core: simulation, worldgen, entities,
        // items, systems, registries, protocol/social value types. No Apple
        // frameworks — this target is the Windows-buildable slice (PORTING 01)
        .target(
            name: "PebbleCoreBase",
            path: "Sources/PebbleCoreBase",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the shared smoke-test suites that need only the portable core —
        // pebsmoke (macOS, full) and pebsmokecore (all platforms) both run
        // these exact checks against the frozen goldens (PORTING 13)
        .target(
            name: "PebbleSmokeKit",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleSmokeKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the engine runtime: GameCore orchestration + Apple-backed services
        // (SQLite saves, Network.framework transport, simd render math).
        // Re-exports PebbleCoreBase so existing imports see the full surface
        .target(
            name: "PebbleCore",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Pebble",
            dependencies: ["PebbleCore"],
            path: "Sources/Pebble",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // headless smoke tests against the frozen golden baselines
        .executableTarget(
            name: "pebsmoke",
            dependencies: ["PebbleCore", "PebbleSmokeKit"],
            path: "Sources/pebsmoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // the deterministic golden suite on the portable core alone — what
        // Windows CI runs to prove worldgen is bit-identical cross-platform
        .executableTarget(
            name: "pebsmokecore",
            dependencies: ["PebbleSmokeKit"],
            path: "Sources/pebsmokecore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // dedicated LAN/SMP server: runs a world headless, no host player
        .executableTarget(
            name: "pebserver",
            dependencies: ["PebbleCore"],
            path: "Sources/pebserver",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

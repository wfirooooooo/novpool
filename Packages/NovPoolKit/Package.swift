// swift-tools-version: 6.0
import PackageDescription

// Swift 6 inserts a runtime check (`swift_task_isCurrentExecutorWithFlagsImpl`) whenever a
// nonisolated closure touches `@MainActor` state. The UI layer is almost entirely such closures
// (SwiftUI result builders, AppKit callbacks, map/filter, …). Those checks have crashed in the
// real app (release + window rendering) at `swift_getObjectType` (EXC_BAD_ACCESS/SIGBUS).
//
// We disable only the *runtime* check. Compile-time Swift 6 concurrency diagnostics
// (isolation, Sendable) stay on, so “touch MainActor from a background thread” is still a
// compile error. Trade-off: a missed cross-thread access will not trap at runtime. UI model
// access happens on AppKit/SwiftUI main-thread callbacks, so we accept that trade-off.
let disableDynamicActorIsolation: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
]

let package = Package(
    name: "NovPoolKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NovPoolCore", targets: ["NovPoolCore"]),
        .library(name: "NovPoolStorage", targets: ["NovPoolStorage"]),
        .library(name: "NovPoolSystemBridge", targets: ["NovPoolSystemBridge"]),
        .library(name: "NovPoolConnectors", targets: ["NovPoolConnectors"]),
        .library(name: "NovPoolUI", targets: ["NovPoolUI"]),
    ],
    targets: [
        // Domain models, contracts, route engine (no UI dependency)
        .target(name: "NovPoolCore"),

        // SQLite (WAL + FTS5), staging files, Keychain, security-scoped bookmarks
        .target(
            name: "NovPoolStorage",
            dependencies: ["NovPoolCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Pasteboard, browser provenance, Vision OCR, content extractors
        .target(
            name: "NovPoolSystemBridge",
            dependencies: ["NovPoolCore", "NovPoolStorage"]
        ),

        // Cloud connectors (local mounts + REST/OAuth)
        .target(
            name: "NovPoolConnectors",
            dependencies: ["NovPoolCore", "NovPoolStorage"]
        ),

        // NSPanel drop zone, click-through host, sectors, search panel
        .target(
            name: "NovPoolUI",
            dependencies: ["NovPoolCore", "NovPoolStorage", "NovPoolSystemBridge", "NovPoolConnectors"],
            swiftSettings: disableDynamicActorIsolation
        ),

        .testTarget(
            name: "NovPoolKitTests",
            dependencies: [
                "NovPoolCore",
                "NovPoolStorage",
                "NovPoolSystemBridge",
                "NovPoolConnectors",
                "NovPoolUI",
            ],
            swiftSettings: disableDynamicActorIsolation
        ),
    ]
)

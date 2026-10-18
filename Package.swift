// swift-tools-version: 6.0
import PackageDescription

/// Workspace root manifest: app executable only; core logic lives in `Packages/NovPoolKit`.
/// Supports fast `swift build` / `swift test` iteration and an Xcode project that references the local package.
let package = Package(
    name: "NovPool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NovPool", targets: ["NovPool"]),
    ],
    dependencies: [
        .package(path: "Packages/NovPoolKit"),
    ],
    targets: [
        .executableTarget(
            name: "NovPool",
            dependencies: [
                .product(name: "NovPoolCore", package: "NovPoolKit"),
                .product(name: "NovPoolStorage", package: "NovPoolKit"),
                .product(name: "NovPoolSystemBridge", package: "NovPoolKit"),
                .product(name: "NovPoolConnectors", package: "NovPoolKit"),
                .product(name: "NovPoolUI", package: "NovPoolKit"),
            ],
            path: "NovPoolApp",
            exclude: ["Info.plist", "NovPool.entitlements", "Assets"],
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])]
        ),
    ]
)

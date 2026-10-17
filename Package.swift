// swift-tools-version: 6.0
import PackageDescription

/// 工作区根 Manifest：只承载 App 可执行目标，核心逻辑全部在 `Packages/NovPoolKit`。
/// 这样既能用 `swift build` / `swift test` 快速迭代，也能让 Xcode 工程直接引用本地包。
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

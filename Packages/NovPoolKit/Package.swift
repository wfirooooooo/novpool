// swift-tools-version: 6.0
import PackageDescription

// Swift 6 的"动态 actor 隔离检查"会在每次从非隔离闭包访问 @MainActor 状态时插入运行时检查
// （`swift_task_isCurrentExecutorWithFlagsImpl`）。UI 层几乎全是这类闭包（SwiftUI 的结果构建器、
// AppKit 回调、map/filter 等泛型函数），而这些检查在真实 app（release + 窗口渲染）里曾稳定
// 崩在 `swift_getObjectType`（EXC_BAD_ACCESS/SIGBUS，两次崩溃地址完全相同）。
//
// 这里只关掉**运行时**检查：编译期的 Swift 6 严格并发诊断（隔离、Sendable）全部保留，
// 因此"从后台线程碰主 actor 状态"这类错误仍然会在编译期被拦下。
// 代价：万一有漏网的跨线程访问，运行时不再自动 trap。UI 层所有模型访问都发生在
// AppKit/SwiftUI 的主线程回调里，因此接受这个代价。
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
        // 领域模型、协议契约、路由规则引擎（零 UI 依赖）
        .target(name: "NovPoolCore"),

        // SQLite(WAL + FTS5) 存储、Staging 文件管理、Keychain 与安全作用域书签
        .target(
            name: "NovPoolStorage",
            dependencies: ["NovPoolCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // 粘贴板解析、浏览器溯源、Vision OCR、JavaScriptCore 清洗
        .target(
            name: "NovPoolSystemBridge",
            dependencies: ["NovPoolCore", "NovPoolStorage"]
        ),

        // 多云连接器（本地云盘挂载直通已实现，REST/OAuth 连接器见 Phase 3）
        .target(
            name: "NovPoolConnectors",
            dependencies: ["NovPoolCore", "NovPoolStorage"]
        ),

        // NSPanel 悬浮窗、点击穿透宿主视图、扇区交互、检索面板
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
            ]
        ),
    ]
)

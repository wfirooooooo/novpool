import AppKit
import NovPoolCore
import NovPoolStorage
import NovPoolUI
import SwiftUI

/// NovPool 以菜单栏 + 桌面悬浮窗常驻，不占用 Dock 栏。
@main
struct NovPoolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        // 无界面自检：不启动 GUI，直接验证数据目录 / 建库 / 暂存 / 入库 / 检索整条链路。
        if args.contains("--selftest") {
            exit(SelfTest.run())
        }
        // Phase A 本机冒烟 / 文件入库 CLI。
        if let code = PhaseASmoke.run(arguments: args) {
            exit(code)
        }
        // 连接器与同步的命令行入口（供脚本化配置与排障）。
        if let code = ConnectorCLI.run(arguments: args) {
            exit(code)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(delegate: appDelegate)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsSceneRoot(delegate: appDelegate)
        }
    }
}

/// 设置窗口的根视图。
///
/// 环境在启动后才装配好，因此**必须在这个视图的 body 里读**（`@Observable` 容器会触发失效重绘）。
/// 若在 scene 闭包里读，SwiftUI 会把「正在启动…」这份内容缓存住，窗口永远不刷新。
@MainActor
struct SettingsSceneRoot: View {
    let delegate: AppDelegate

    var body: some View {
        if let environment = delegate.holder.environment {
            SettingsView(
                store: environment.settingsStore,
                onRunSyncNow: { await environment.runSyncNow() },
                onResetPanelPosition: { environment.resetPanelPosition() },
                onRevealDataDirectory: { environment.revealDataDirectory() },
                logPath: NovPoolLog.path
            )
        } else {
            ProgressView("正在启动…")
                .frame(width: 720, height: 520)
        }
    }
}

/// 菜单栏图标：黑洞单色剪影，声明为模板图以自动适配深浅色菜单栏。
struct MenuBarIcon: View {
    var body: some View {
        if let image = MenuBarIconSizing.prepared(Bundle.main.image(forResource: "blackhole-template")) {
            return AnyView(
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: MenuBarIconSizing.pointSize.width,
                        height: MenuBarIconSizing.pointSize.height
                    )
            )
        }
        return AnyView(Image(systemName: "tray.and.arrow.down.fill"))
    }
}

@MainActor
struct MenuBarContent: View {
    let delegate: AppDelegate

    var body: some View {
        // 同样在这里读环境：菜单内容在启动瞬间会被构建一次，只有读到 @Observable 容器
        // 才能在环境就绪后刷新出真正的菜单项。
        if let environment = delegate.holder.environment {
            let lang = environment.settingsStore.uiLanguage
            Text(environment.statusSummary)
            Divider()
            Button(AppL10n.t(.menuSearch, lang)) { environment.toggleSearchPanel() }
                .keyboardShortcut(.space, modifiers: [.command, .shift])
            SettingsLink { Text(AppL10n.t(.menuSettings, lang)) }
                .keyboardShortcut(",", modifiers: .command)
            Button(AppL10n.t(.menuShowPanel, lang)) { environment.showPanel() }
            Button(AppL10n.t(.menuHidePanel, lang)) { environment.hidePanel() }
            Button(AppL10n.t(.menuResetPanel, lang)) { environment.resetPanelPosition() }
            Divider()
            Button(AppL10n.t(.menuDataDir, lang)) { environment.revealDataDirectory() }
            Button(AppL10n.t(.menuArchiveDir, lang)) { environment.revealArchiveDirectory() }
        } else {
            Text(AppL10n.t(.menuStarting, AppLanguage.load()))
        }
        Divider()
        Button(AppL10n.t(.menuQuit, AppLanguage.load())) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 环境在启动完成后才装配好，而设置窗口可能在此之前就被打开。
    /// 用一个 `@Observable` 容器承载它，SwiftUI 才能在装配完成后自动刷新窗口内容
    /// （否则窗口会永远停在「正在启动…」）。
    @Observable
    final class EnvironmentHolder {
        var environment: AppEnvironment?
    }

    let holder = EnvironmentHolder()

    var environment: AppEnvironment? { holder.environment }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NovPoolLog.startSession()
        // 库层的诊断信息统一写进启动日志。
        NovPoolDiagnostics.sink = { message in NovPoolLog.write(message) }
        NovPoolLog.write(
            "NovPool 启动，bundle=\(Bundle.main.bundleIdentifier ?? "无") 版本=\(Bundle.main.shortVersion)"
        )
        // 与 Info.plist 的 LSUIElement 一致，运行期也保持「菜单栏工具」形态。
        NSApp.setActivationPolicy(.accessory)

        Task {
            do {
                let environment = try await AppEnvironment.bootstrap()
                holder.environment = environment
                environment.start()
            } catch {
                let reason = (error as? NovPoolError)?.errorDescription ?? "\(error)"
                NovPoolLog.write("启动失败：\(reason)")
                presentFatalError(reason)
            }
        }
    }

    /// 启动失败必须让人看得见：`open` 启动时 stderr 无处可看，静默退出等于「执行完脚本什么都没发生」。
    private func presentFatalError(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "NovPool 启动失败"
        alert.informativeText = "\(reason)\n\n详细日志：\(NovPoolLog.path)"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

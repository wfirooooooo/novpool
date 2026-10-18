import AppKit
import NovPoolCore
import NovPoolStorage
import NovPoolUI
import SwiftUI

/// NovPool stays in the menu bar + desktop drop zone; it does not take a Dock slot.
@main
struct NovPoolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        // Headless self-test: skip GUI and verify data dir / DB / staging / ingest / search.
        if args.contains("--selftest") {
            exit(SelfTest.run())
        }
        // Phase A local smoke / file-ingest CLI.
        if let code = PhaseASmoke.run(arguments: args) {
            exit(code)
        }
        // Connector + sync CLI (scripted setup and troubleshooting).
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

/// Root view for the Settings window.
///
/// The environment is wired after launch, so it **must** be read inside this view's body
/// (`@Observable` invalidates redraws). Reading it in the scene closure caches the
/// “Starting…” placeholder and the window never refreshes.
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
            ProgressView("Starting…")
                .frame(width: 720, height: 520)
        }
    }
}

/// Menu bar icon: monochrome black-hole silhouette, template image for light/dark bars.
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
        // Same pattern: the menu is built once at launch; reading the @Observable holder
        // lets it refresh once the environment is ready.
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
    /// Environment is ready only after bootstrap; Settings may open earlier.
    /// Hold it in an `@Observable` box so SwiftUI refreshes when assembly finishes
    /// (otherwise the window stays on “Starting…” forever).
    @Observable
    final class EnvironmentHolder {
        var environment: AppEnvironment?
    }

    let holder = EnvironmentHolder()

    var environment: AppEnvironment? { holder.environment }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NovPoolLog.startSession()
        // Funnel library diagnostics into the startup log.
        NovPoolDiagnostics.sink = { message in NovPoolLog.write(message) }
        NovPoolLog.write(
            "NovPool starting, bundle=\(Bundle.main.bundleIdentifier ?? "none") version=\(Bundle.main.shortVersion)"
        )
        // Match Info.plist LSUIElement: stay a menu-bar accessory at runtime.
        NSApp.setActivationPolicy(.accessory)

        Task {
            do {
                let environment = try await AppEnvironment.bootstrap()
                holder.environment = environment
                environment.start()
            } catch {
                let reason = (error as? NovPoolError)?.errorDescription ?? "\(error)"
                NovPoolLog.write("Startup failed: \(reason)")
                presentFatalError(reason)
            }
        }
    }

    /// Startup failures must be visible: `open` discards stderr, so a silent exit looks like nothing ran.
    private func presentFatalError(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "NovPool failed to start"
        alert.informativeText = "\(reason)\n\nLog: \(NovPoolLog.path)"
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

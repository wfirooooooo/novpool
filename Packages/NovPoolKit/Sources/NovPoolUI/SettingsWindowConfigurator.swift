import AppKit
import SwiftUI

/// 让设置窗口始终浮在最上层。
///
/// 菜单栏应用（`LSUIElement`）没有常规主窗口，设置窗口很容易被压在别的应用后面，
/// 用户点了「设置…」却看不到东西。这里在窗口挂载后把它提到浮动层并激活应用。
///
/// 注意：`.canJoinAllSpaces` 与 `.moveToActiveSpace` 互斥，同时设置会让 AppKit
/// 抛 `NSInternalInconsistencyException`（本项目曾因此在启动阶段崩溃），所以只用前者。
public struct SettingsWindowConfigurator: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    public static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

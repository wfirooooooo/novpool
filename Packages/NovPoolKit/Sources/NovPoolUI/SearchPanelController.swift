import AppKit
import Foundation
import NovPoolStorage
import SwiftUI

/// 检索面板控制器：装配面板、注册全局快捷键、管理焦点归还。
@MainActor
public final class SearchPanelController: NSObject, NSWindowDelegate {
    public let panel: SearchPanel
    /// 视图模型需要在 `super.init()` 之后构造（它的 `onDismiss` 要回调本对象），
    /// 因此这里用隐式解包：构造完成后立即赋值，外部拿到的永远是有效实例。
    public private(set) var viewModel: SearchViewModel!

    private var hotKey: GlobalHotKey?
    private var previousApp: NSRunningApplication?
    private let quickLookController = LocalFileQuickLookController()

    public init(
        search: @escaping @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult],
        loadCategories: @escaping @MainActor @Sendable () async -> [String] = { [] },
        hotKeySpec: HotKeySpec = .default,
        contentSize: CGSize = SearchPanelLayout.resolvedContentSize(),
        actions: SearchActions? = nil
    ) {
        self.panel = SearchPanel(contentSize: contentSize)
        super.init()

        // 无论外部是否注入动作，Quick Look 都走本控制器持有的实例，避免单例并发告警。
        let base = actions ?? SearchPanelController.liveActions { _ in false }
        let quickLook = quickLookController
        let resolvedActions = SearchActions(
            openURL: base.openURL,
            revealFile: base.revealFile,
            copyText: base.copyText,
            deleteItem: base.deleteItem,
            quickLookFile: { url in quickLook.present(url: url) },
            updateOrganization: base.updateOrganization,
            resummarizeItem: base.resummarizeItem
        )
        self.viewModel = SearchViewModel(
            search: search,
            loadCategories: loadCategories,
            actions: resolvedActions,
            onDismiss: { [weak self] in self?.hide() }
        )

        let resolvedSize = SearchPanelLayout.clamp(contentSize)
        let host = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        host.frame = NSRect(origin: .zero, size: resolvedSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setContentSize(resolvedSize)
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        hotKey = GlobalHotKey(spec: hotKeySpec) { [weak self] in
            self?.toggle()
        }
    }

    /// 快捷键是否注册成功（可能被系统或其他应用占用）。
    public var isHotKeyRegistered: Bool { hotKey != nil }

    /// 设置热生效：释放旧热键并按新规格重新注册。
    @discardableResult
    public func updateHotKey(_ spec: HotKeySpec) -> Bool {
        hotKey = nil
        hotKey = GlobalHotKey(spec: spec) { [weak self] in
            self?.toggle()
        }
        return hotKey != nil
    }

    public var isVisible: Bool { panel.isVisible }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show() {
        // 记住当前前台应用，收起时把焦点还回去（菜单栏工具的礼仪）。
        previousApp = NSWorkspace.shared.frontmostApplication
        if let screen = SearchPanelPlacement.screenForMouse(
            screens: NSScreen.screens,
            mouseLocation: NSEvent.mouseLocation
        ) {
            panel.setFrameOrigin(
                SearchPanelPlacement.origin(in: screen.visibleFrame, contentSize: panel.frame.size)
            )
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        viewModel.activate()
    }

    public func hide() {
        panel.orderOut(nil)
        let target = previousApp
        previousApp = nil
        target?.activate()
    }

    /// 点到别处自动收起（Spotlight 习惯）。
    public func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        hide()
    }

    /// 用户拖完窗口边角后记住尺寸，下次呼出沿用。
    public func windowDidEndLiveResize(_ notification: Notification) {
        SearchPanelLayout.persistContentSize(panel.frame.size)
    }

    // MARK: - 真实动作实现

    public static func liveActions(
        deleteItem: @escaping @MainActor @Sendable (UUID) async throws -> Bool,
        updateOrganization: @escaping @MainActor @Sendable (UUID, KnowledgeOrganization) async throws -> Void = { _, _ in },
        resummarizeItem: @escaping @MainActor @Sendable (UUID) async -> String = { _ in "未接线" }
    ) -> SearchActions {
        SearchActions(
            openURL: { url in NSWorkspace.shared.open(url) },
            revealFile: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            copyText: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            deleteItem: deleteItem,
            updateOrganization: updateOrganization,
            resummarizeItem: resummarizeItem
        )
    }
}

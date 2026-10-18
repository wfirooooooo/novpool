import AppKit
import Foundation
import NovPoolStorage
import SwiftUI

/// Search panel controller: builds the panel, registers the global hotkey, restores focus.
@MainActor
public final class SearchPanelController: NSObject, NSWindowDelegate {
    public let panel: SearchPanel
    /// The view model must be built after `super.init()` (its `onDismiss` callbacks into self),
    /// so this uses an implicitly unwrapped optional: assigned right after init; callers always see a valid instance.
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

        // Regardless of injected actions, Quick Look uses this controller's instance to avoid singleton concurrency warnings.
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

    /// Whether the hotkey registered (may be taken by the system or another app).
    public var isHotKeyRegistered: Bool { hotKey != nil }

    /// Apply settings live: release the old hotkey and re-register with the new spec.
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
        // Remember the frontmost app and restore focus on dismiss (menu-bar tool etiquette).
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

    /// Dismiss when clicking elsewhere (Spotlight habit).
    public func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        hide()
    }

    /// Remember the size after the user resizes, reuse on next open.
    public func windowDidEndLiveResize(_ notification: Notification) {
        SearchPanelLayout.persistContentSize(panel.frame.size)
    }

    // MARK: - Real action implementations

    public static func liveActions(
        deleteItem: @escaping @MainActor @Sendable (UUID) async throws -> Bool,
        updateOrganization: @escaping @MainActor @Sendable (UUID, KnowledgeOrganization) async throws -> Void = { _, _ in },
        resummarizeItem: @escaping @MainActor @Sendable (UUID) async -> String = { _ in "Not wired" }
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

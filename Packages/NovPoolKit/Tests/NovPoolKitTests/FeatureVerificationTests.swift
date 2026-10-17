import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import SwiftUI
import Testing
@testable import NovPoolSystemBridge
@testable import NovPoolUI

/// 无头环境能验证的部分：几何、窗口配置、权限降级。
@Suite("功能自检（无头可验证部分）")
@MainActor
struct FeatureVerificationTests {
    // MARK: - 全局拖拽命中

    @Test("拖到图标上才算投递：排除普通点击与窗口拖动")
    func dragDropThreshold() {
        let icon = CGRect(x: 2000, y: 900, width: 48, height: 48)
        #expect(GlobalDragMonitor.isDrop(iconRect: icon, point: CGPoint(x: 2020, y: 920), movedDistance: 40))
        // 位移不足：只是点了图标
        #expect(!GlobalDragMonitor.isDrop(iconRect: icon, point: CGPoint(x: 2020, y: 920), movedDistance: 2))
        // 落点在图标外
        #expect(!GlobalDragMonitor.isDrop(iconRect: icon, point: CGPoint(x: 1900, y: 800), movedDistance: 400))
    }

    @Test("悬浮窗图标矩形：以画布中心为锚、48pt 见方，随窗口位置平移")
    func panelIconRect() {
        let viewModel = CaptureViewModel { _, _ in
            CaptureOutcome(title: "自检", isDuplicate: false, routeTargets: [])
        }
        let controller = PanelController(viewModel: viewModel, screen: nil)
        controller.panel.setFrameOrigin(NSPoint(x: 1_000, y: 500))

        let rect = controller.iconScreenRect
        #expect(rect.width == NovPoolLayout.iconSize)
        #expect(rect.height == NovPoolLayout.iconSize)
        #expect(rect.midX == controller.panel.frame.midX)
        #expect(rect.midY == controller.panel.frame.midY)
        #expect(rect.midX == 1_000 + NovPoolLayout.canvasSize.width / 2)
        #expect(rect.midY == 500 + NovPoolLayout.canvasSize.height / 2)
    }

    // MARK: - 设置窗口

    @Test("设置窗口提到浮动层、跟随所有 Space，且不触发互斥的 collectionBehavior")
    func settingsWindowConfiguration() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        SettingsWindowConfigurator.configure(window)

        #expect(window.level == .floating)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        // 这两个同时设置会让 AppKit 抛 NSInternalInconsistencyException（曾导致启动崩溃）
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
    }

    // MARK: - 权限降级

    @Test("未授予辅助功能权限时，读取选中文字安静返回 nil 而不是报错")
    func axSelectionDegradesGracefully() {
        guard !AXIsProcessTrusted() else { return }   // 已授权环境不适用
        #expect(AXSelectionReader().selectedText() == nil)
    }
}

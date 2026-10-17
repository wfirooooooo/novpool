import AppKit
import Foundation
import NovPoolStorage
import Testing
@testable import NovPoolUI

/// 启动链路控制器的构造回归：曾经因为检索面板同时设置了两个互斥的
/// `NSWindow.CollectionBehavior`，在构造时抛 NSInternalInconsistencyException。
/// 这个测试逐个构造三个控制器，任何一步抛异常/挂起都会让测试失败。
@Suite("控制器构造回归")
@MainActor
struct ControllerConstructionTests {
    @Test("逐个构造：视图模型 → 悬浮窗控制器 → 检索面板控制器")
    func constructsAllControllers() {
        print("PROBE-1 构造 CaptureViewModel")
        let viewModel = CaptureViewModel { _, _ in
            CaptureOutcome(title: "probe", isDuplicate: false, routeTargets: [])
        }
        print("PROBE-2 构造 PanelController")
        let panelController = PanelController(viewModel: viewModel)
        _ = panelController
        print("PROBE-3 构造 SearchPanelController")
        let searchController = SearchPanelController(search: { _ in [] })
        _ = searchController
        print("PROBE-4 全部完成")
    }
}

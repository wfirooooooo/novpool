import Foundation
import NovPoolCore

/// 悬浮窗渲染快照。
///
/// 为什么需要它：SwiftUI 结果构建器里的闭包（`ForEach` 的 content、`ZStack` 的 content、
/// `onAppear`…）签名都是**非隔离**的。在这些闭包里直接读 `@MainActor @Observable` 模型，
/// 编译器会插入运行时"当前执行器"检查（`swift_task_isCurrentExecutor…`）。
/// 该检查在真实窗口渲染 + release 优化下出现过 `EXC_BAD_ACCESS`（踩坏指针）。
///
/// 因此视图只消费这份纯值快照：闭包里不再出现任何模型访问，检查自然消失。
struct PanelSnapshot: Equatable {
    struct Chip: Equatable, Identifiable {
        var id: String
        var title: String
        var systemImage: String
        /// 相对环心的偏移（SwiftUI 坐标：y 向下为正）。
        var offset: CGPoint
        var isHighlighted: Bool
    }

    var isExpanded: Bool
    var isBusy: Bool
    var statusText: String?
    var statusIsError: Bool
    var ringOffset: CGSize
    var ringRadius: CGFloat
    var chips: [Chip]

    @MainActor
    init(viewModel: CaptureViewModel) {
        isExpanded = viewModel.isExpanded
        isBusy = viewModel.isBusy
        statusText = viewModel.statusText
        statusIsError = viewModel.statusIsError
        ringOffset = viewModel.ringOffset
        ringRadius = viewModel.ringRadius

        // 关键：先在 init 作用域（main actor）把模型状态取成局部值，
        // 再交给非隔离的 map 闭包。闭包字面量传给 map / filter / sorted 这类
        // 非隔离泛型函数时，闭包类型也是非隔离的——在里面读 @MainActor 状态
        // 会插入运行时隔离检查，而该检查在真实 app 里曾稳定崩在
        // `swift_task_isCurrentExecutorWithFlagsImpl`。
        let zones = viewModel.zones
        let highlightedIndex = viewModel.highlightedZoneIndex

        // AppKit 视图坐标（y 向上）→ SwiftUI 偏移（y 向下）
        let offsets = SectorLayout.chipOffsets(
            zoneCount: zones.count,
            radius: viewModel.ringRadius
        )
        chips = zones.enumerated().map { index, zone in
            let offset = offsets.indices.contains(index) ? offsets[index] : .zero
            return Chip(
                id: zone.id,
                title: zone.title,
                systemImage: zone.systemImage,
                offset: offset,
                isHighlighted: highlightedIndex == index
            )
        }
    }

    /// 主图标命中区域（静默态）/ 整块画布（展开态）。
    func interactiveRect(canvasSize: CGSize, iconSize: CGFloat) -> CGRect {
        isExpanded
            ? CGRect(origin: .zero, size: canvasSize)
            : CGRect(
                x: (canvasSize.width - iconSize) / 2,
                y: (canvasSize.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
    }
}

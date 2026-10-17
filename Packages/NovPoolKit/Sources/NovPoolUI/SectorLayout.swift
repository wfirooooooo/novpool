import AppKit
import Foundation
import NovPoolCore

/// 扇区环的布局求解：让四个投递槽位尽量完整落在屏幕可见区域内。
///
/// 为什么需要它：图标可以自由拖动，而扇区是绕图标按固定半径展开的。图标一旦贴近屏幕边缘，
/// 朝屏幕外的槽位就会被裁掉、够不到。这里的做法是**把环心朝屏幕内侧平移**（图标保持不动），
/// 平移量受画布大小限制，因此在图标贴边时仍能保持完整可用的四向扇区。
public enum SectorLayout {
    public static let preferredRadius: CGFloat = 84
    /// 空间实在不够时的下限半径；低于它槽位会挤在图标上。
    public static let minimumRadius: CGFloat = 56
    public static let chipSize = CGSize(width: 66, height: 52)

    public struct Resolved: Sendable, Equatable {
        /// 环心（画布坐标）。
        public var center: CGPoint
        public var radius: CGFloat

        /// 环心相对画布中心的偏移；SwiftUI 布局与拖拽命中判定共用它，两者必须始终一致。
        public var offset: CGSize {
            CGSize(width: center.x - canvasCenter.x, height: center.y - canvasCenter.y)
        }

        var canvasCenter: CGPoint
    }

    /// 求解环心与半径。
    ///
    /// - Parameters:
    ///   - iconCenter: 主图标中心（画布坐标）
    ///   - canvasSize: 固定画布尺寸
    ///   - visibleFrameInCanvas: 屏幕可见区域换算到画布坐标后的矩形
    public static func resolve(
        iconCenter: CGPoint,
        canvasSize: CGSize,
        visibleFrameInCanvas: CGRect,
        preferredRadius: CGFloat = SectorLayout.preferredRadius,
        chipSize: CGSize = SectorLayout.chipSize
    ) -> Resolved {
        let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var radius = preferredRadius
        var half = halfExtent(radius: radius, chipSize: chipSize)

        // 可见区域本身就装不下整环时（极小窗口 / 极端分辨率）先缩半径，
        // 宁可环小一点，也不要槽位落在屏幕外。
        let maxFitRadius = min(
            (visibleFrameInCanvas.width - chipSize.width) / 2,
            (visibleFrameInCanvas.height - chipSize.height) / 2
        )
        if maxFitRadius < radius {
            radius = max(minimumRadius, maxFitRadius)
            half = halfExtent(radius: radius, chipSize: chipSize)
        }

        let safeInScreen = visibleFrameInCanvas.insetBy(dx: half.width, dy: half.height)
        let safeInCanvas = CGRect(origin: .zero, size: canvasSize).insetBy(dx: half.width, dy: half.height)
        let safe = safeInScreen.intersection(safeInCanvas)

        guard !safe.isNull, safe.width > 0, safe.height > 0 else {
            // 连一个合法环心都没地方放：退回绕图标展开，至少行为可预测。
            return Resolved(center: iconCenter, radius: radius, canvasCenter: canvasCenter)
        }

        let center = CGPoint(
            x: min(max(iconCenter.x, safe.minX), safe.maxX),
            y: min(max(iconCenter.y, safe.minY), safe.maxY)
        )
        return Resolved(center: center, radius: radius, canvasCenter: canvasCenter)
    }

    /// 环在某个方向上的半跨度：半径 + 槽位半宽/半高。
    static func halfExtent(radius: CGFloat, chipSize: CGSize = SectorLayout.chipSize) -> CGSize {
        CGSize(width: radius + chipSize.width / 2, height: radius + chipSize.height / 2)
    }

    /// 预先算好每个槽位中心的偏移量（相对环心），`PanelRootView` 与命中判定共用同一套几何。
    public static func chipOffsets(zoneCount: Int, radius: CGFloat) -> [CGPoint] {
        (0..<max(zoneCount, 0)).map { index in
            let offset = SectorGeometry.zoneCenter(index: index, zoneCount: zoneCount, radius: radius)
            // AppKit 视图坐标 y 轴向上，而 SectorGeometry 返回的是 SwiftUI 屏幕方向偏移。
            return CGPoint(x: offset.x, y: -offset.y)
        }
    }
}

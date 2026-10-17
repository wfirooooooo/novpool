import CoreGraphics
import Foundation

/// 扇区几何计算：把拖拽悬停点换算成投递槽位索引。
///
/// 纯数学、无 AppKit 依赖，便于单元测试。坐标系为 AppKit 视图坐标（原点左下）。
public enum SectorGeometry {
    /// 主图标半径（48x48 pt 图标的一半），在此半径内视为「未离开图标」。
    public static let deadZoneRadius: CGFloat = 24
    /// 扇区环形可命中的最大半径（固定 260x260 画布内）。
    public static let maxRadius: CGFloat = 110

    /// 返回命中的槽位索引；`nil` 表示落在死区或画布之外，应保持静默态。
    public static func zoneIndex(
        for point: CGPoint,
        center: CGPoint,
        zoneCount: Int
    ) -> Int? {
        guard zoneCount > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > deadZoneRadius, distance <= maxRadius else { return nil }

        // 第一个扇区位于正上方，顺时针均分。
        let angleFromTop = atan2(dx, dy) // 0 = 正上，右正左负
        let normalized = (angleFromTop + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let sectorWidth = 2 * CGFloat.pi / CGFloat(zoneCount)
        // 先偏移半个扇区再取整：让「扇区中心」精确落在整数索引上，
        // 避免正上 / 正右等边界角度因浮点误差落到相邻扇区。
        let index = Int((normalized / sectorWidth + 0.5).rounded(.down))
        return index % zoneCount
    }

    /// 槽位中心相对画布中心的坐标，供 SwiftUI 布局使用。
    public static func zoneCenter(index: Int, zoneCount: Int, radius: CGFloat) -> CGPoint {
        guard zoneCount > 0 else { return .zero }
        let step = 2 * CGFloat.pi / CGFloat(zoneCount)
        let angle = CGFloat(index) * step // 0 = 正上，顺时针
        return CGPoint(x: radius * sin(angle), y: radius * cos(angle))
    }
}

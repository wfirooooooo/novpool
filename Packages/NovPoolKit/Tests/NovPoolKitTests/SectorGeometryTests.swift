import Foundation
import Testing
@testable import NovPoolCore

@Suite("扇区几何")
struct SectorGeometryTests {
    private let center = CGPoint(x: 130, y: 130)

    @Test("四个扇区按上 → 右 → 下 → 左顺时针分布")
    func clockwiseQuadrants() {
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 130, y: 200), center: center, zoneCount: 4) == 0)
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 200, y: 130), center: center, zoneCount: 4) == 1)
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 130, y: 60), center: center, zoneCount: 4) == 2)
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 60, y: 130), center: center, zoneCount: 4) == 3)
    }

    @Test("图标死区内不命中任何扇区")
    func deadZone() {
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 135, y: 135), center: center, zoneCount: 4) == nil)
    }

    @Test("超出最大半径不命中，保证画布外的拖拽不被劫持")
    func outOfBounds() {
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 130, y: 260), center: center, zoneCount: 4) == nil)
    }

    @Test("槽位中心与命中判定互为逆运算")
    func roundTrip() {
        for count in [2, 3, 4] {
            for index in 0..<count {
                let offset = SectorGeometry.zoneCenter(index: index, zoneCount: count, radius: 84)
                let point = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
                #expect(SectorGeometry.zoneIndex(for: point, center: center, zoneCount: count) == index)
            }
        }
    }
}

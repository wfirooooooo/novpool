import Foundation
import Testing
@testable import NovPoolCore

@Suite("Sector Geometry")
struct SectorGeometryTests {
    private let center = CGPoint(x: 130, y: 130)

    @Test("The four sectors are arranged clockwise in the order: top → right → bottom → left")
    func clockwiseQuadrants() {
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 130, y: 200), center: center, zoneCount: 4) == 0)
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 200, y: 130), center: center, zoneCount: 4) == 1)
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 130, y: 60), center: center, zoneCount: 4) == 2)
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 60, y: 130), center: center, zoneCount: 4) == 3)
    }

    @Test("Does not hit any sector within the icon dead zone")
    func deadZone() {
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 135, y: 135), center: center, zoneCount: 4) == nil)
    }

    @Test("Misses if it exceeds the maximum radius, ensuring that dragging outside the canvas is not hijacked")
    func outOfBounds() {
        #expect(SectorGeometry.zoneIndex(for: CGPoint(x: 130, y: 260), center: center, zoneCount: 4) == nil)
    }

    @Test("The slot center and hit detection are inverse operations of each other")
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

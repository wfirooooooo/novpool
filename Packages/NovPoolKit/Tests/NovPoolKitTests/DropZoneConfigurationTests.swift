import Foundation
import NovPoolCore
import Testing
@testable import NovPoolUI

@Suite("扇区槽位配置")
struct DropZoneConfigurationTests {
    @Test("未配置时回退到内置默认槽位")
    func defaultsWhenEmpty() {
        #expect(DropZoneConfiguration.zones(from: nil) == DropZone.defaultZones)
        #expect(DropZoneConfiguration.zones(from: "") == DropZone.defaultZones)
        #expect(DropZoneConfiguration.zones(from: "{ 不是 JSON") == DropZone.defaultZones)
    }

    @Test("编解码往返一致")
    func roundTrip() throws {
        let zones = [
            DropZone(id: "smart", title: "智能路由", systemImage: "wand.and.stars"),
            DropZone(id: "notes", title: "笔记库", systemImage: "doc.text", connectorID: "obsidian"),
        ]
        let encoded = DropZoneConfiguration.encode(zones)
        #expect(DropZoneConfiguration.decode(encoded) == zones)
    }

    @Test("规整：丢弃空标题、去重、截断超长标题、限制最多四个")
    func sanitizing() {
        let messy = [
            DropZone(id: "a", title: "  ", systemImage: "x"),
            DropZone(id: "b", title: "标题很长很长很长很长很长很长", systemImage: "doc"),
            DropZone(id: "b", title: "重复 ID", systemImage: "doc"),
            DropZone(id: "c", title: "三", systemImage: "doc"),
            DropZone(id: "d", title: "四", systemImage: "doc"),
            DropZone(id: "e", title: "五", systemImage: "doc"),
        ]
        let sanitized = DropZoneConfiguration.sanitize(messy)
        #expect(sanitized.count == DropZoneConfiguration.maximumZones)
        #expect(sanitized.map(\.id) == ["b", "c", "d", "e"])
        #expect(sanitized[0].title.count == 12)
    }

    @Test("全是无效槽位时退回默认值，保证扇区永远可用")
    func fallsBackWhenAllInvalid() {
        let invalid = [DropZone(id: " ", title: " ", systemImage: "")]
        #expect(DropZoneConfiguration.sanitize(invalid) == DropZone.defaultZones)
    }

    @Test("空白 connectorID 视为智能路由槽位")
    func blankConnectorBecomesSmartRoute() throws {
        let zones = DropZoneConfiguration.sanitize([
            DropZone(id: "x", title: "智能", systemImage: "wand.and.stars", connectorID: "   "),
        ])
        #expect(zones.first?.connectorID == nil)
        #expect(zones.first?.isSmartRoute == true)
    }
}

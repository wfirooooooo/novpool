import Foundation
import NovPoolCore
import Testing
@testable import NovPoolUI

@Suite("Sector Slot Configuration")
struct DropZoneConfigurationTests {
    @Test("If not configured, fallback to the default slot 'Save locally'")
    func defaultsWhenEmpty() {
        #expect(DropZone.defaultZones.count == 1)
        #expect(DropZone.defaultZones[0].isSmartRoute)
        #expect(DropZone.defaultZones[0].title == "Save locally")
        #expect(DropZoneConfiguration.zones(from: nil) == DropZone.defaultZones)
        #expect(DropZoneConfiguration.zones(from: "") == DropZone.defaultZones)
        #expect(DropZoneConfiguration.zones(from: "{ not JSON") == DropZone.defaultZones)
    }

    @Test("Codec round-trip consistency")
    func roundTrip() throws {
        let zones = [
            DropZone(id: "smart", title: "Smart route", systemImage: "wand.and.stars"),
            DropZone(id: "notes", title: "Notes", systemImage: "doc.text", connectorID: "obsidian"),
        ]
        let encoded = DropZoneConfiguration.encode(zones)
        #expect(DropZoneConfiguration.decode(encoded) == zones)
    }

    @Test("Standardize: discard empty titles, remove duplicates, truncate overly long titles, limit to a maximum of four")
    func sanitizing() {
        let messy = [
            DropZone(id: "a", title: "  ", systemImage: "x"),
            DropZone(id: "b", title: "A very very very very very long title", systemImage: "doc"),
            DropZone(id: "b", title: "Duplicate ID", systemImage: "doc"),
            DropZone(id: "c", title: "Three", systemImage: "doc"),
            DropZone(id: "d", title: "Four", systemImage: "doc"),
            DropZone(id: "e", title: "Five", systemImage: "doc"),
        ]
        let sanitized = DropZoneConfiguration.sanitize(messy)
        #expect(sanitized.count == DropZoneConfiguration.maximumZones)
        #expect(sanitized.map(\.id) == ["b", "c", "d", "e"])
        #expect(sanitized[0].title.count == 12)
    }

    @Test("Return to the default value when all slots are invalid, ensuring the sector is always usable")
    func fallsBackWhenAllInvalid() {
        let invalid = [DropZone(id: " ", title: " ", systemImage: "")]
        #expect(DropZoneConfiguration.sanitize(invalid) == DropZone.defaultZones)
    }

    @Test("A blank connectorID is regarded as an intelligent routing slot")
    func blankConnectorBecomesSmartRoute() throws {
        let zones = DropZoneConfiguration.sanitize([
            DropZone(id: "x", title: "Smart", systemImage: "wand.and.stars", connectorID: "   "),
        ])
        #expect(zones.first?.connectorID == nil)
        #expect(zones.first?.isSmartRoute == true)
    }
}

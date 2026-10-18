import Foundation
import NovPoolCore

/// Configuration read and write of floating window sector slots.
///
/// A slot is a shortcut for 'where to send when dragging,' and it must allow users to customize it: change the title, replace the icon, and bind it to which connector.
/// The configuration exists in `UserDefaults` as JSON; if parsing fails, it will always fall back to the built-in default values, never allowing the floating window to fail to open.
public enum DropZoneConfiguration {
    /// The floating window can display up to four sectors at the same time (limited by the fixed canvas and ring layout).
    public static let maximumZones = 4
    public static let defaultsKey = "novpool.zones"

    public static func decode(_ raw: String?) -> [DropZone]? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let zones = try? JSONDecoder().decode([DropZone].self, from: data) else { return nil }
        return sanitize(zones)
    }

    public static func encode(_ zones: [DropZone]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sanitize(zones)), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// Fallback: `nil` means the user has not configured it, so the built-in default four slots are used.
    public static func zones(from raw: String?) -> [DropZone] {
        decode(raw) ?? DropZone.defaultZones
    }

    /// Normalization: remove empty titles, remove duplicate IDs, limit quantity; if the result is empty, return to the default value (empty sectors are not allowed).
    public static func sanitize(_ zones: [DropZone]) -> [DropZone] {
        var seen = Set<String>()
        var result: [DropZone] = []
        for zone in zones {
            let id = zone.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = zone.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { continue }
            result.append(DropZone(
                id: id,
                title: String(title.prefix(12)),
                systemImage: zone.systemImage.trimmingCharacters(in: .whitespacesAndNewlines),
                connectorID: zone.connectorID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ))
            if result.count == maximumZones { break }
        }
        return result.isEmpty ? DropZone.defaultZones : result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

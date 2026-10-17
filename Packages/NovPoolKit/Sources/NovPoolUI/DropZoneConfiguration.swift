import Foundation
import NovPoolCore

/// 悬浮窗扇区槽位的配置读写。
///
/// 槽位是「拖拽时往哪送」的快捷入口，必须允许用户自定义：改标题、换图标、绑定到哪个连接器。
/// 配置以 JSON 存在 `UserDefaults` 里；解析失败一律回退到内置默认值，绝不让悬浮窗开不起来。
public enum DropZoneConfiguration {
    /// 悬浮窗最多同时显示四个扇区（固定画布与环形布局所限）。
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

    /// 兜底：`nil` 表示用户没配置过，用内置默认四槽位。
    public static func zones(from raw: String?) -> [DropZone] {
        decode(raw) ?? DropZone.defaultZones
    }

    /// 规整：去空标题、去重 ID、限制数量；结果为空则退回默认值（不允许出现空扇区）。
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

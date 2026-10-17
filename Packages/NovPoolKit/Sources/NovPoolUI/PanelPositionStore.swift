import AppKit
import Foundation

/// 悬浮窗位置的持久化（`UserDefaults`，编码成 `"x,y"` 便于 `defaults read` 直接看）。
///
/// 不声明 `Sendable`：`UserDefaults` 本身不是 `Sendable`，而本类型只在主 actor 上使用
/// （面板位置读写都发生在 UI 线程），标成 `Sendable` 反而是在撒谎。
public struct PanelPositionStore {
    public static let defaultKey = "novpool.panel.origin"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = PanelPositionStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> NSPoint? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return Self.decode(raw)
    }

    public func save(_ origin: NSPoint) {
        defaults.set(Self.encode(origin), forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    static func encode(_ origin: NSPoint) -> String {
        String(format: "%.1f,%.1f", origin.x, origin.y)
    }

    static func decode(_ raw: String) -> NSPoint? {
        let pieces = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count == 2,
              let x = Double(pieces[0]),
              let y = Double(pieces[1]),
              x.isFinite, y.isFinite else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }
}

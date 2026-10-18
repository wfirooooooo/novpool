import AppKit
import Foundation

/// Persistence of the floating window position (`UserDefaults`, encoded as "x,y" for easy direct viewing with `defaults read`).
///
/// Not declaring `Sendable`: `UserDefaults` itself is not `Sendable`, and this type is only used on the main actor
///  (Reading and writing the panel position both occur on the UI thread), marking it as `Sendable` is actually lying.
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

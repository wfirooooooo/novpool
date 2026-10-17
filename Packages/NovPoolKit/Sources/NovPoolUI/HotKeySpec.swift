import Carbon.HIToolbox
import Foundation

/// 全局快捷键规格：`cmd+shift+space` 这类字符串 ↔ Carbon 虚拟键码。
///
/// 用系统 Carbon 的 `RegisterEventHotKey` 而不是第三方库：不需要辅助功能授权，
/// 也不依赖 Keychain / 网络，符合「零外部依赖」的工程约束。
public struct HotKeySpec: Sendable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    /// 用于界面展示，例如 `⌘⇧Space`。
    public var displayName: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayName = displayName
    }

    /// 默认呼出组合：⌘⇧Space。
    public static let `default` = HotKeySpec(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayName: "⇧⌘Space"
    )

    /// 解析 `cmd+shift+space` / `⌥+space` 这类写法；无法识别时返回 `nil`。
    public init?(named raw: String) {
        let pieces = raw
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyToken = pieces.last, pieces.count > 1 else { return nil }
        guard let keyCode = Self.keyCodes[keyToken] else { return nil }

        var modifiers: UInt32 = 0
        for token in pieces.dropLast() {
            switch token {
            case "cmd", "command", "⌘":
                modifiers |= UInt32(cmdKey)
            case "shift", "⇧":
                modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt", "⌥":
                modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃":
                modifiers |= UInt32(controlKey)
            default:
                return nil
            }
        }

        self.init(
            keyCode: keyCode,
            carbonModifiers: modifiers,
            displayName: Self.symbols(for: modifiers) + Self.displayNames[keyToken, default: keyToken.uppercased()]
        )
    }

    /// 按 macOS 约定顺序（⌃⌥⇧⌘）输出修饰键符号，
    /// 这样 `shift+cmd+k` 与 `cmd+shift+k` 得到同一个展示名与同一个规格。
    static func symbols(for modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    /// ANSI 虚拟键码（与 `kVK_*` 常量一致）。
    static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        "space": UInt32(kVK_Space), "tab": UInt32(kVK_Tab), "return": UInt32(kVK_Return),
        "escape": UInt32(kVK_Escape), "delete": UInt32(kVK_Delete),
        "/": UInt32(kVK_ANSI_Slash), ".": UInt32(kVK_ANSI_Period), ",": UInt32(kVK_ANSI_Comma),
        ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
        "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
        "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
        "`": UInt32(kVK_ANSI_Grave), "\\": UInt32(kVK_ANSI_Backslash),
    ]

    static let displayNames: [String: String] = [
        "space": "Space", "tab": "Tab", "return": "↩", "escape": "⎋", "delete": "⌫",
    ]
}

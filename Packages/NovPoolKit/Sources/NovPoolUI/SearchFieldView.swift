import AppKit
import SwiftUI

/// 搜索输入框（包装 `NSTextField`）。
///
/// 为什么不用 SwiftUI `TextField`：上下方向键、回车、esc 需要稳定落到我们的导航逻辑上，
/// 而 `TextField` 会先消费掉一部分按键。走 AppKit 的 `doCommandBy` 是最可靠的路径。
struct SearchFieldView: NSViewRepresentable {
    var text: String
    var placeholder: String
    var focusToken: Int
    // 回调声明为 @MainActor：闭包声明位置（面板视图）与调用位置（Coordinator）
    // 都在主 actor 上，这样闭包体内访问视图模型不会插入运行时隔离检查。
    var onTextChange: @MainActor (String) -> Void
    var onMoveUp: @MainActor () -> Void
    var onMoveDown: @MainActor () -> Void
    var onSubmit: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        context.coordinator.lastFocusToken = focusToken
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchFieldView
        var lastFocusToken: Int = .min

        init(parent: SearchFieldView) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

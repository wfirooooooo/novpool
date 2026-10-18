import AppKit
import SwiftUI

/// Search input box (wraps `NSTextField`).
///
/// Why not use SwiftUI `TextField`: the up and down arrow keys, Enter, and Esc need to reliably map to our navigation logic.
/// And `TextField` will first consume part of the key presses. Going through AppKit's `doCommandBy` is the most reliable path.
struct SearchFieldView: NSViewRepresentable {
    var text: String
    var placeholder: String
    var focusToken: Int
    // Callback declared as @MainActor: closure declaration location (panel view) and call location (Coordinator)
    // All are on the main actor, so accessing the view model inside the closure will not insert runtime isolation checks.
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

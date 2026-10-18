import AppKit
import SwiftUI

/// Keep the settings window always on top.
///
/// The menu bar app (`LSUIElement`) does not have a regular main window, so the settings window can easily be hidden behind other applications.
/// The user clicked "Settings…" but couldn't see anything. Here it is brought to the floating layer and activates the application after being mounted in the window.
///
/// Note: `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually exclusive; setting both will cause AppKit
/// Throw `NSInternalInconsistencyException` (this previously caused a crash during the startup phase), so only the former is used.
public struct SettingsWindowConfigurator: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    public static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

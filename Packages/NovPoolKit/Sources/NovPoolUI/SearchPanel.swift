import AppKit
import Foundation

/// Search panel layout constants (nonisolated; shared by UI and tests).
public enum SearchPanelLayout {
    public static let contentSize = CGSize(width: 780, height: 520)
    public static let minimumContentSize = CGSize(width: 640, height: 400)
    public static let minimumListColumnWidth: CGFloat = 280
    public static let minimumPreviewColumnWidth: CGFloat = 260

    public static let contentSizeDefaultsKey = "novpool.searchPanel.contentSize"

    /// Read the user-resized window size; fall back to default if invalid or too small.
    public static func resolvedContentSize(
        defaults: UserDefaults = .standard
    ) -> CGSize {
        guard let raw = defaults.string(forKey: contentSizeDefaultsKey) else {
            return contentSize
        }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return contentSize
        }
        return clamp(CGSize(width: width, height: height))
    }

    public static func persistContentSize(
        _ size: CGSize,
        defaults: UserDefaults = .standard
    ) {
        let clamped = clamp(size)
        defaults.set(
            "\(Int(clamped.width.rounded()))x\(Int(clamped.height.rounded()))",
            forKey: contentSizeDefaultsKey
        )
    }

    public static func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(minimumContentSize.width, size.width),
            height: max(minimumContentSize.height, size.height)
        )
    }
}

/// Search panel: resizable frosted card that accepts keyboard input, so `canBecomeKey` is `true`.
///
/// Opposite of the drag floating panel (`.nonactivatingPanel` + click-through): this panel steals focus for typing,
/// then restores focus to the previous frontmost app when closed.
@MainActor
public final class SearchPanel: NSPanel {
    public static let defaultContentSize = SearchPanelLayout.contentSize

    public init(contentSize: CGSize = SearchPanelLayout.resolvedContentSize()) {
        let size = SearchPanelLayout.clamp(contentSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Note: .canJoinAllSpaces and .moveToActiveSpace conflict; setting both makes AppKit
        // throw NSInternalInconsistencyException while constructing the window and terminate.
        // The search panel is hotkey-invoked; the correct behavior is to move to the active Space.
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // Same as Settings: opaque system window fill so ultraThinMaterial does not darken the desktop.
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = SearchPanelLayout.minimumContentSize
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// Search panel placement: horizontally centered, slightly above vertical center (Spotlight/Raycast habit),
/// and on the screen that contains the mouse.
public enum SearchPanelPlacement {
    public static func origin(
        in visibleFrame: NSRect,
        contentSize: CGSize = SearchPanelLayout.contentSize,
        verticalRatio: CGFloat = 0.72
    ) -> NSPoint {
        // Ideal: centered horizontally, slightly high; then clamp into the visible area so a larger panel stays on-screen.
        var x = visibleFrame.midX - contentSize.width / 2
        var y = visibleFrame.minY + visibleFrame.height * verticalRatio - contentSize.height / 2
        let maxX = visibleFrame.maxX - contentSize.width
        let maxY = visibleFrame.maxY - contentSize.height
        if maxX >= visibleFrame.minX {
            x = min(max(x, visibleFrame.minX), maxX)
        }
        if maxY >= visibleFrame.minY {
            y = min(max(y, visibleFrame.minY), maxY)
        }
        return NSPoint(x: x, y: y)
    }

    /// Index of the screen under the mouse (more intuitive on multi-monitor); fall back to the first screen.
    public static func screenIndex(containing point: NSPoint, frames: [NSRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        return frames.firstIndex { NSMouseInRect(point, $0, false) } ?? 0
    }

    public static func screenForMouse(screens: [NSScreen], mouseLocation: NSPoint) -> NSScreen? {
        guard let index = screenIndex(containing: mouseLocation, frames: screens.map(\.frame)) else {
            return nil
        }
        return screens[index]
    }
}

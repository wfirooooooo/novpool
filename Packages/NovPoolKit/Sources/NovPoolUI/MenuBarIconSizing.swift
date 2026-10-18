import AppKit
import Foundation

/// The size of the status icons in the menu bar is standardized.
///
/// The standard display size for macOS status bar icons is 18×18 points. If the bitmap resource is 256×256 pixels and there is no explicit setting
/// `NSImage.size`, the system will render it at '256×256 points' — the icon will be ridiculously large in the menu bar.
/// Here, the point size is fixed to maintain consistency with other applications.
public enum MenuBarIconSizing {
    public static let pointSize = CGSize(width: 18, height: 18)

    /// Organize into a template diagram + standard point dimensions.
    public static func prepared(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        image.isTemplate = true
        image.size = pointSize
        return image
    }
}

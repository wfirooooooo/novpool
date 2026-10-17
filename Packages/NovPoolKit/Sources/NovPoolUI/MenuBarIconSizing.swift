import AppKit
import Foundation

/// 菜单栏状态图标的尺寸规整。
///
/// macOS 状态栏图标的标准显示尺寸是 18×18 点。位图资源若是 256×256 像素、又没有显式设置
/// `NSImage.size`，系统会按「256×256 点」渲染——图标在菜单栏里会大得离谱。
/// 这里把点尺寸钉死，保持与其他应用一致。
public enum MenuBarIconSizing {
    public static let pointSize = CGSize(width: 18, height: 18)

    /// 规整为模板图 + 标准点尺寸。
    public static func prepared(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        image.isTemplate = true
        image.size = pointSize
        return image
    }
}

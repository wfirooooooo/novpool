import AppKit
import Foundation
import NovPoolCore

/// `NSPasteboard` 真实实现。
///
/// `NSPasteboard` 不是 `Sendable`，这里显式声明为 `@unchecked Sendable`，
/// 并约定只在主线程（拖拽回调所在的 `@MainActor` 上下文）构造与使用。
public final class NSPasteboardReader: PasteboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var availableTypeIdentifiers: [String] {
        pasteboard.types?.map(\.rawValue) ?? []
    }

    public func data(forTypeIdentifier typeIdentifier: String) -> Data? {
        pasteboard.data(forType: NSPasteboard.PasteboardType(typeIdentifier))
    }

    public func string(forTypeIdentifier typeIdentifier: String) -> String? {
        pasteboard.string(forType: NSPasteboard.PasteboardType(typeIdentifier))
    }
}

/// 类型标识符到文件扩展名的映射（P1 图片落盘时使用）。
enum ImageTypeMapping {
    static let preferences: [(typeIdentifier: String, fileExtension: String)] = [
        (PasteboardTypeID.png, "png"),
        (PasteboardTypeID.jpeg, "jpg"),
        (PasteboardTypeID.tiff, "tiff"),
        // 直接拖拽网页视频元素时，个别浏览器会把媒体字节放进粘贴板
        (PasteboardTypeID.mpeg4Movie, "mp4"),
        (PasteboardTypeID.movie, "mov"),
        (PasteboardTypeID.quickTimeMovie, "mov"),
    ]

    static func fileExtension(for typeIdentifier: String) -> String {
        preferences.first { $0.typeIdentifier == typeIdentifier }?.fileExtension ?? "dat"
    }
}

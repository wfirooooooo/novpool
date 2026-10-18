import AppKit
import Foundation
import NovPoolCore

/// The actual implementation of `NSPasteboard`.
///
/// `NSPasteboard` is not `Sendable`, so it is explicitly declared here as `@unchecked Sendable`,
/// And it is agreed to only construct and use on the main thread (the `@MainActor` context where the drag callback is located).
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

    public func allStrings(forTypeIdentifier typeIdentifier: String) -> [String] {
        let type = NSPasteboard.PasteboardType(typeIdentifier)
        if let items = pasteboard.pasteboardItems, items.count > 1 {
            let values = items.compactMap { $0.string(forType: type) }
            if !values.isEmpty { return values }
        }
        if let raw = pasteboard.string(forType: type) {
            return raw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
        return []
    }
}

/// Mapping of type identifiers to file extensions (used when saving P1 images).
enum ImageTypeMapping {
    static let preferences: [(typeIdentifier: String, fileExtension: String)] = [
        (PasteboardTypeID.png, "png"),
        (PasteboardTypeID.jpeg, "jpg"),
        (PasteboardTypeID.tiff, "tiff"),
        // When directly dragging the WebVideo element, some browsers will put the media bytes into the clipboard
        (PasteboardTypeID.mpeg4Movie, "mp4"),
        (PasteboardTypeID.movie, "mov"),
        (PasteboardTypeID.quickTimeMovie, "mov"),
    ]

    static func fileExtension(for typeIdentifier: String) -> String {
        preferences.first { $0.typeIdentifier == typeIdentifier }?.fileExtension ?? "dat"
    }
}

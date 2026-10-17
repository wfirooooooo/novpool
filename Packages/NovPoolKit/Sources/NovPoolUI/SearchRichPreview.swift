import AppKit
import AVFoundation
import NovPoolStorage
import PDFKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

/// 检索详情区的媒体预览（图 / PDF / 视频海报 / 文件缩略图）。
@MainActor
struct SearchRichPreview: View {
    let kind: SearchPreviewKind
    let fileURL: URL
    var maxHeight: CGFloat = 180

    var body: some View {
        Group {
            switch kind {
            case .image:
                LocalImagePreview(url: fileURL, maxHeight: maxHeight)
            case .pdf:
                PDFPreviewRepresentable(url: fileURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .video:
                VideoPosterPreview(url: fileURL, maxHeight: maxHeight)
            case .fileThumbnail:
                FileThumbnailPreview(url: fileURL, maxHeight: min(maxHeight, 120))
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 列表行用的小缩略图（仅图片 / 有缩略图的文件）。
@MainActor
struct SearchResultThumbnail: View {
    let kind: SearchPreviewKind
    let fileURL: URL?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let fileURL {
                switch kind {
                case .image:
                    LocalImagePreview(url: fileURL, maxHeight: size, cornerRadius: 5)
                        .frame(width: size, height: size)
                case .pdf, .video, .fileThumbnail:
                    FileThumbnailPreview(url: fileURL, maxHeight: size, cornerRadius: 5)
                        .frame(width: size, height: size)
                case .none:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - 图片

@MainActor
struct LocalImagePreview: View {
    let url: URL
    var maxHeight: CGFloat = 180
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                previewPlaceholder(systemName: "photo", height: maxHeight)
            }
        }
        .task(id: url) {
            image = LocalPreviewLoader.image(at: url)
        }
    }
}

// MARK: - PDF

@MainActor
struct PDFPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.textBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - 视频海报

@MainActor
struct VideoPosterPreview: View {
    let url: URL
    var maxHeight: CGFloat = 180

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .center) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                previewPlaceholder(systemName: "film", height: maxHeight)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 4)
        }
        .task(id: url) {
            image = await LocalPreviewLoader.videoPoster(at: url)
        }
    }
}

// MARK: - Quick Look 缩略图

@MainActor
struct FileThumbnailPreview: View {
    let url: URL
    var maxHeight: CGFloat = 120
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                previewPlaceholder(systemName: "doc", height: maxHeight)
            }
        }
        .task(id: url) {
            image = await LocalPreviewLoader.quickLookThumbnail(at: url, maxPixelSize: max(maxHeight * 2, 128))
        }
    }
}

// MARK: - 加载

enum LocalPreviewLoader {
    static func image(at url: URL) -> NSImage? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func videoPoster(at url: URL, atSeconds: Double = 0.3) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: atSeconds, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    static func quickLookThumbnail(at url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}

// MARK: - Quick Look 面板

/// 用系统 Quick Look 面板预览单个本机文件（「预览」按钮）。
///
/// QLPreview 回调是非隔离的，因此本类不标 `@MainActor`；由 `SearchPanelController` 持有实例。
public final class LocalFileQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let lock = NSLock()
    private var previewURL: URL?

    public override init() {
        super.init()
    }

    @MainActor
    public func present(url: URL) {
        lock.lock()
        previewURL = url
        lock.unlock()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return previewURL == nil ? 0 : 1
    }

    public func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> any QLPreviewItem {
        lock.lock()
        defer { lock.unlock() }
        return (previewURL ?? URL(filePath: "/")) as QLPreviewItem
    }
}

// MARK: - 占位

@MainActor
private func previewPlaceholder(systemName: String, height: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05))
        Image(systemName: systemName)
            .font(.system(size: 22))
            .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
}

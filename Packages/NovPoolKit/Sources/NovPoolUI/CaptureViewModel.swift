import Foundation
import NovPoolCore
import NovPoolSystemBridge
import Observation

/// 一次投递的回执摘要，用于悬浮窗状态提示。
public struct CaptureOutcome: Sendable, Equatable {
    public var title: String
    public var isDuplicate: Bool
    /// 本次投递命中的路由目标（Phase 3 起由发件箱真正推送）。
    public var routeTargets: [String]

    public init(title: String, isDuplicate: Bool, routeTargets: [String]) {
        self.title = title
        self.isDuplicate = isDuplicate
        self.routeTargets = routeTargets
    }
}

/// 悬浮窗交互状态模型。所有 UI 状态都在 `@MainActor` 上，保证主线程响应预算。
@MainActor
@Observable
public final class CaptureViewModel {
    public var zones: [DropZone]
    public private(set) var isExpanded = false
    public private(set) var highlightedZoneIndex: Int?
    public private(set) var isBusy = false
    public private(set) var statusText: String?
    public private(set) var statusIsError = false
    /// 扇区环心相对画布中心的偏移：图标贴边时会朝屏幕内侧平移，保证四个槽位都在屏幕内。
    public private(set) var ringOffset: CGSize = .zero
    public private(set) var ringRadius: CGFloat = SectorLayout.preferredRadius

    private let handler: @Sendable (ResolvedDragContent, DropZone?) async throws -> CaptureOutcome
    private var statusTask: Task<Void, Never>?

    public init(
        zones: [DropZone] = DropZone.defaultZones,
        handler: @escaping @Sendable (ResolvedDragContent, DropZone?) async throws -> CaptureOutcome
    ) {
        self.zones = zones
        self.handler = handler
    }

    public var highlightedZone: DropZone? {
        guard let index = highlightedZoneIndex, zones.indices.contains(index) else { return nil }
        return zones[index]
    }

    // MARK: - 拖拽会话

    public func dragSessionBegan() {
        isExpanded = true
    }

    /// 由面板控制器在落位变化时调用，布局与命中判定共用同一份几何。
    public func updateRingLayout(_ resolved: SectorLayout.Resolved) {
        ringOffset = resolved.offset
        ringRadius = resolved.radius
    }

    public func zoneChanged(_ index: Int?) {
        highlightedZoneIndex = index
    }

    public func dragSessionEnded() {
        isExpanded = false
        highlightedZoneIndex = nil
    }

    public func handleDrop(_ content: ResolvedDragContent, zoneIndex: Int?) {
        let zone = zoneIndex.flatMap { zones.indices.contains($0) ? zones[$0] : nil }
        dragSessionEnded()
        isBusy = true

        Task { [handler] in
            defer { isBusy = false }
            do {
                let outcome = try await handler(content, zone)
                showStatus(Self.describe(outcome), isError: false)
            } catch {
                showStatus(Self.describe(error), isError: true)
            }
        }
    }

    // MARK: - 状态提示

    /// 供后台阶段（OCR / 正文提取 / AI 增强）回写提示，不改变当前忙闲状态。
    public func showTransientStatus(_ text: String, isError: Bool = false) {
        showStatus(text, isError: isError)
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusTask?.cancel()
        statusText = text
        statusIsError = isError
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusText = nil
        }
    }

    static func describe(_ outcome: CaptureOutcome) -> String {
        if outcome.isDuplicate {
            return "已存在：\(outcome.title)"
        }
        if outcome.routeTargets.isEmpty {
            return "已收录：\(outcome.title)"
        }
        return "已收录 → \(outcome.routeTargets.joined(separator: "、"))：\(outcome.title)"
    }

    static func describe(_ error: any Error) -> String {
        if let novPoolError = error as? NovPoolError {
            return novPoolError.errorDescription ?? "投递失败"
        }
        return error.localizedDescription
    }
}

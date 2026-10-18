import Foundation
import NovPoolCore
import NovPoolSystemBridge
import Observation

/// Capture outcome summary for the floating panel status.
public struct CaptureOutcome: Sendable, Equatable {
    public var title: String
    public var isDuplicate: Bool
    /// Route targets hit by this drop (Phase 3 onward, pushed via the outbox).
    public var routeTargets: [String]

    public init(title: String, isDuplicate: Bool, routeTargets: [String]) {
        self.title = title
        self.isDuplicate = isDuplicate
        self.routeTargets = routeTargets
    }
}

/// Floating panel interaction model. All UI state is `@MainActor` for main-thread budget.
@MainActor
@Observable
public final class CaptureViewModel {
    public var zones: [DropZone]
    public private(set) var isExpanded = false
    public private(set) var highlightedZoneIndex: Int?
    public private(set) var isBusy = false
    public private(set) var statusText: String?
    public private(set) var statusIsError = false
    /// Ring-center offset from canvas center: when the icon is near an edge, shift inward so all four slots stay on-screen.
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

    // MARK: - Drag session

    public func dragSessionBegan() {
        isExpanded = true
    }

    /// Called by the panel controller on reposition; layout and hit-testing share the same geometry.
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
        let items = content.expandedForIngest()
        dragSessionEnded()
        isBusy = true

        Task { [handler] in
            defer { isBusy = false }
            do {
                var outcomes: [CaptureOutcome] = []
                outcomes.reserveCapacity(items.count)
                for item in items {
                    outcomes.append(try await handler(item, zone))
                }
                showStatus(Self.describe(outcomes), isError: false)
            } catch {
                showStatus(Self.describe(error), isError: true)
            }
        }
    }

    // MARK: - Status

    /// Background stages (OCR / extract / AI) write status here without changing busy state.
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
            return "Already exists: \(outcome.title)"
        }
        if outcome.routeTargets.isEmpty {
            return "Saved: \(outcome.title)"
        }
        return "Saved → \(outcome.routeTargets.joined(separator: ", ")): \(outcome.title)"
    }

    /// Summary line for a multi-file drop.
    static func describe(_ outcomes: [CaptureOutcome]) -> String {
        guard let first = outcomes.first else { return "Saved" }
        guard outcomes.count > 1 else { return describe(first) }

        let saved = outcomes.filter { !$0.isDuplicate }.count
        let duplicates = outcomes.count - saved
        if duplicates == 0 {
            return "Saved \(saved) items"
        }
        if saved == 0 {
            return "Already exists \(duplicates) items"
        }
        return "Saved \(saved), skipped \(duplicates) duplicates"
    }

    static func describe(_ error: any Error) -> String {
        if let novPoolError = error as? NovPoolError {
            return novPoolError.errorDescription ?? "Capture failed"
        }
        return error.localizedDescription
    }
}

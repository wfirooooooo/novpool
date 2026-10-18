import Foundation
import NovPoolCore

/// Floating window render snapshot.
///
/// Why you need it: closures in SwiftUI result builders (`ForEach`'s content, `ZStack`'s content,
/// `onAppear`…) signatures are all **non-isolated**. In these closures, you can directly read `@MainActor @Observable` models,
/// The compiler will insert a runtime "Current executor" check (`swift_task_isCurrentExecutor…`).
/// This check has experienced `EXC_BAD_ACCESS` (dereferenced a bad pointer) under real window rendering + release optimization.
///
/// Therefore, the view only consumes this pure value snapshot: there is no longer any model access in the closure, and the inspection naturally disappears.
struct PanelSnapshot: Equatable {
    struct Chip: Equatable, Identifiable {
        var id: String
        var title: String
        var systemImage: String
        /// Offset relative to the center of the circle (SwiftUI coordinates: y is positive downward).
        var offset: CGPoint
        var isHighlighted: Bool
    }

    var isExpanded: Bool
    var isBusy: Bool
    var statusText: String?
    var statusIsError: Bool
    var ringOffset: CGSize
    var ringRadius: CGFloat
    var chips: [Chip]

    @MainActor
    init(viewModel: CaptureViewModel) {
        isExpanded = viewModel.isExpanded
        isBusy = viewModel.isBusy
        statusText = viewModel.statusText
        statusIsError = viewModel.statusIsError
        ringOffset = viewModel.ringOffset
        ringRadius = viewModel.ringRadius

        // Key: first, in the init scope (main actor), take the model state as a local value,
        // Then pass it to a non-isolated map closure. Closure literals are passed to map / filter / sorted, etc.
        // When a non-isolated generic function, the closure type is also non-isolated—reading @MainActor state inside
        // Runtime isolation checks will be inserted, and this check has previously caused stable crashes in real apps
        // `swift_task_isCurrentExecutorWithFlagsImpl`.
        let zones = viewModel.zones
        let highlightedIndex = viewModel.highlightedZoneIndex

        // AppKit view coordinates (y up) → SwiftUI offset (y down)
        let offsets = SectorLayout.chipOffsets(
            zoneCount: zones.count,
            radius: viewModel.ringRadius
        )
        chips = zones.enumerated().map { index, zone in
            let offset = offsets.indices.contains(index) ? offsets[index] : .zero
            return Chip(
                id: zone.id,
                title: zone.title,
                systemImage: zone.systemImage,
                offset: offset,
                isHighlighted: highlightedIndex == index
            )
        }
    }

    /// Main icon hit area (idle state) / entire canvas (expanded state).
    func interactiveRect(canvasSize: CGSize, iconSize: CGFloat) -> CGRect {
        isExpanded
            ? CGRect(origin: .zero, size: canvasSize)
            : CGRect(
                x: (canvasSize.width - iconSize) / 2,
                y: (canvasSize.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
    }
}

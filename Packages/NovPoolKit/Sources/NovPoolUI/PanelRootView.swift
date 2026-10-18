import NovPoolCore
import SwiftUI

/// Floating window root view: fixed canvas + central icon + elastic expanding sectors.
///
/// The view only consumes `PanelSnapshot` (pure value) and does not access the `@MainActor` model inside SwiftUI closures—
/// The reason is explained in the comments of `PanelSnapshot`.
@MainActor
public struct PanelRootView: View {
    private let viewModel: CaptureViewModel

    private let canvasSize: CGSize
    private let iconSize: CGFloat

    public init(
        viewModel: CaptureViewModel,
        canvasSize: CGSize = NovPoolLayout.canvasSize,
        iconSize: CGFloat = NovPoolLayout.iconSize
    ) {
        self.viewModel = viewModel
        self.canvasSize = canvasSize
        self.iconSize = iconSize
    }

    public var body: some View {
        // The snapshot takes values within the body scope: here is the main actor, and once taken, it is pure data.
        render(PanelSnapshot(viewModel: viewModel))
    }

    private func render(_ snapshot: PanelSnapshot) -> some View {
        ZStack {
            Color.clear

            if snapshot.isExpanded {
                RingBackdrop(radius: snapshot.ringRadius, offset: snapshot.ringOffset)
            }

            ChipRing(chips: snapshot.chips, ringOffset: snapshot.ringOffset, isExpanded: snapshot.isExpanded)
            IconBadge(isBusy: snapshot.isBusy, size: iconSize)

            if let status = snapshot.statusText {
                StatusPill(
                    text: status,
                    isError: snapshot.statusIsError,
                    maxWidth: canvasSize.width - 32,
                    yOffset: canvasSize.height / 2 - 26
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        // Right-clicking the floating icon = shortcut access. If the drop-down path under the menu bar is cached by the system,
        // You can still access the settings here, it's not completely blocked.
        .contextMenu {
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit NovPool") { NSApp.terminate(nil) }
        }
    }
}

/// Expanded ring-shaped frosted glass backing.
struct RingBackdrop: View {
    let radius: CGFloat
    let offset: CGSize

    var body: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .frame(width: radius * 2 + 70, height: radius * 2 + 70)
            .offset(x: offset.width, y: -offset.height)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

/// Four delivery slots.
struct ChipRing: View {
    let chips: [PanelSnapshot.Chip]
    let ringOffset: CGSize
    let isExpanded: Bool

    var body: some View {
        ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
            ZoneChip(title: chip.title, systemImage: chip.systemImage, isHighlighted: chip.isHighlighted)
                .offset(
                    x: chip.offset.x + ringOffset.width,
                    y: chip.offset.y - ringOffset.height
                )
                .scaleEffect(isExpanded ? 1 : 0.1)
                .opacity(isExpanded ? 1 : 0)
                .animation(
                    .spring(response: 0.28, dampingFraction: 0.75).delay(Double(index) * 0.02),
                    value: isExpanded
                )
        }
    }
}

/// Central main icon.
struct IconBadge: View {
    let isBusy: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = Self.floatingIcon() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                // Fallback when resources are missing (for example, running `swift run` directly from the source code without a .app bundle)
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.primary)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .offset(x: size * 0.18, y: -size * 0.18)
            }
        }
        .frame(width: size, height: size)
    }

    /// Black hole pattern (transparent background PNG, originally created by scripts/render-blackhole-icon.swift).
    static func floatingIcon() -> NSImage? {
        Bundle.main.image(forResource: "blackhole")
    }
}

/// Bottom status messages.
struct StatusPill: View {
    let text: String
    let isError: Bool
    let maxWidth: CGFloat
    let yOffset: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            .foregroundStyle(isError ? Color.red : Color.primary)
            .frame(maxWidth: maxWidth)
            .offset(y: yOffset)
            .transition(.opacity)
    }
}

/// Single sector slot.
struct ZoneChip: View {
    let title: String
    let systemImage: String
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .frame(width: 66, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isHighlighted
                        ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                        : AnyShapeStyle(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHighlighted ? 0.35 : 0.12), lineWidth: 0.5)
        )
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .scaleEffect(isHighlighted ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHighlighted)
    }
}

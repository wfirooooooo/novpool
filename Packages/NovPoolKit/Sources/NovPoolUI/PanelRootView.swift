import NovPoolCore
import SwiftUI

/// 悬浮窗根视图：固定画布 + 中心图标 + 弹性展开扇区。
///
/// 视图只消费 `PanelSnapshot`（纯值），不在 SwiftUI 闭包里访问 `@MainActor` 模型——
/// 理由见 `PanelSnapshot` 的注释。
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
        // 快照在 body 作用域内取值：这里是 main actor，取完就是纯数据。
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
        // 右键悬浮图标 = 快捷入口。菜单栏下拉那条路若被系统缓存住内容，
        // 这里仍然能进设置，不至于被堵死。
        .contextMenu {
            SettingsLink { Text("设置…") }
            Divider()
            Button("退出 NovPool") { NSApp.terminate(nil) }
        }
    }
}

/// 展开态的环形毛玻璃底衬。
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

/// 四个投递槽位。
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

/// 中心主图标。
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
                // 资源缺失时的兜底（例如从源码直接 swift run、没有 .app bundle）
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

    /// 黑洞图案（透明背景 PNG，由 scripts/render-blackhole-icon.swift 原创绘制）。
    static func floatingIcon() -> NSImage? {
        Bundle.main.image(forResource: "blackhole")
    }
}

/// 底部状态提示。
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

/// 单个扇区槽位。
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

import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import SwiftUI
import Testing
@testable import NovPoolSystemBridge
@testable import NovPoolUI

/// Parts that can be verified in a headless environment: geometry, window configuration, permission degradation.
@Suite("Function self-check (headless verifiable part)")
@MainActor
struct FeatureVerificationTests {
    // MARK: - Global Drag Hit

    @Test("Delivery only counts when dragged onto the icon: excludes regular clicks and window dragging")
    func dragDropThreshold() {
        let icon = CGRect(x: 2000, y: 900, width: 48, height: 48)
        #expect(GlobalDragMonitor.isDrop(iconRect: icon, point: CGPoint(x: 2020, y: 920), movedDistance: 40))
        // Insufficient displacement: only clicked the icon
        #expect(!GlobalDragMonitor.isDrop(iconRect: icon, point: CGPoint(x: 2020, y: 920), movedDistance: 2))
        // The landing point is outside the icon
        #expect(!GlobalDragMonitor.isDrop(iconRect: icon, point: CGPoint(x: 1900, y: 800), movedDistance: 400))
    }

    @Test("Floating window icon rectangle: anchored at the center of the canvas, 48pt square, moves with the window position")
    func panelIconRect() {
        let viewModel = CaptureViewModel { _, _ in
            CaptureOutcome(title: "Self-check", isDuplicate: false, routeTargets: [])
        }
        let controller = PanelController(viewModel: viewModel, screen: nil)
        controller.panel.setFrameOrigin(NSPoint(x: 1_000, y: 500))

        let rect = controller.iconScreenRect
        #expect(rect.width == NovPoolLayout.iconSize)
        #expect(rect.height == NovPoolLayout.iconSize)
        #expect(rect.midX == controller.panel.frame.midX)
        #expect(rect.midY == controller.panel.frame.midY)
        #expect(rect.midX == 1_000 + NovPoolLayout.canvasSize.width / 2)
        #expect(rect.midY == 500 + NovPoolLayout.canvasSize.height / 2)
    }

    // MARK: - Settings window

    @Test("Set the window to mention the floating layer, follow all Spaces, and not trigger the mutually exclusive collectionBehavior")
    func settingsWindowConfiguration() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        SettingsWindowConfigurator.configure(window)

        #expect(window.level == .floating)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        // Setting both of these at the same time will cause AppKit to throw NSInternalInconsistencyException (once caused startup crashes)
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
    }

    // MARK: - Permission downgrade

    @Test("When accessibility permissions are not granted, readSelectedText quietly returns nil instead of throwing an error")
    func axSelectionDegradesGracefully() {
        guard !AXIsProcessTrusted() else { return }   // The authorized environment is not applicable
        #expect(AXSelectionReader().selectedText() == nil)
    }
}

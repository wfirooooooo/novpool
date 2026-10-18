import AppKit
import Foundation
import NovPoolStorage
import Testing
@testable import NovPoolUI

/// Initiate the constructor regression of the link controller: Previously, because the retrieval panel simultaneously set two mutually exclusive
/// `NSWindow.CollectionBehavior` throws NSInternalInconsistencyException during initialization.
/// This test constructs three controllers one by one, and any step throwing an exception or hanging will cause the test to fail.
@Suite("Controller Construction Regression")
@MainActor
struct ControllerConstructionTests {
    @Test("Construct one by one: View Model → Floating Window Controller → Retrieval Panel Controller")
    func constructsAllControllers() {
        print("PROBE-1 Construct CaptureViewModel")
        let viewModel = CaptureViewModel { _, _ in
            CaptureOutcome(title: "probe", isDuplicate: false, routeTargets: [])
        }
        print("PROBE-2 Construct PanelController")
        let panelController = PanelController(viewModel: viewModel)
        _ = panelController
        print("PROBE-3 Construct SearchPanelController")
        let searchController = SearchPanelController(search: { _ in [] })
        _ = searchController
        print("PROBE-4 AllComplete")
    }
}

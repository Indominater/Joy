import AppKit
import SwiftUI
import XCTest
@testable import Joy

final class JoyCursorPolicyTests: XCTestCase {
    @MainActor
    func testArrowPolicyOwnsInactivePanelTrackingWithoutDisablingCursorRects() throws {
        _ = NSApplication.shared
        let panel = makePanel()
        let hostingView = JoyArrowHostingView(rootView: EmptyView())
        hostingView.frame = panel.contentLayoutRect
        panel.contentView = hostingView

        panel.installArrowOnlyCursorPolicy()
        panel.installArrowOnlyCursorPolicy()

        XCTAssertTrue(panel.areCursorRectsEnabled)
        let ownedAreas = hostingView.trackingAreas.filter {
            $0.owner === panel
        }
        let area = try XCTUnwrap(ownedAreas.first)
        XCTAssertEqual(ownedAreas.count, 1)
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.mouseMoved))
        XCTAssertTrue(area.options.contains(.activeAlways))
        XCTAssertTrue(area.options.contains(.inVisibleRect))
        XCTAssertTrue(area.options.contains(.enabledDuringMouseDrag))
        XCTAssertFalse(area.options.contains(.cursorUpdate))
    }

    @MainActor
    func testArrowTrackingMovesWhenContentViewIsReplaced() {
        _ = NSApplication.shared
        let panel = makePanel()
        let firstView = JoyArrowHostingView(rootView: EmptyView())
        let secondView = JoyArrowHostingView(rootView: EmptyView())

        panel.contentView = firstView
        panel.installArrowOnlyCursorPolicy()
        panel.contentView = secondView
        panel.installArrowOnlyCursorPolicy()

        XCTAssertFalse(firstView.trackingAreas.contains { $0.owner === panel })
        XCTAssertTrue(secondView.trackingAreas.contains { $0.owner === panel })
    }

    @MainActor
    private func makePanel() -> JoyPanel {
        JoyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 212),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}

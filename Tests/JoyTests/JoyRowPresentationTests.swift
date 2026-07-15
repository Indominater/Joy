import AppKit
import CoreText
import Foundation
import SwiftUI
import XCTest
@testable import Joy

final class JoyRowPresentationTests: XCTestCase {
    func testPanelUsesThreeRowThreeTwoFootprint() {
        XCTAssertEqual(JoyPanelLayout.frameSize.height, 184)
        XCTAssertEqual(JoyPanelLayout.frameSize.width, 276)
        XCTAssertEqual(JoyPanelLayout.contentSize.height, 172)
        XCTAssertEqual(
            JoyPanelLayout.frameSize.width / JoyPanelLayout.frameSize.height,
            3 / 2
        )
    }

    func testStatusPillTopAndTrailingMarginsMatch() {
        let topInset = (
            JoyRowLayout.height - JoyRowLayout.statusPillHeight
        ) / 2

        XCTAssertEqual(JoyRowLayout.statusEdgeInset, 8)
        XCTAssertEqual(JoyRowLayout.statusEdgeInset, topInset)
        XCTAssertEqual(
            JoyRowLayout.rowCornerRadius,
            JoyRowLayout.statusPillHeight / 2
        )
    }

    func testTripleDigitStatusTimerFitsAtFullFontSize() throws {
        let fallback = NSFont.systemFont(
            ofSize: JoyRowLayout.statusFontSize,
            weight: .semibold
        )
        let roundedDescriptor = fallback.fontDescriptor.withDesign(.rounded)
            ?? fallback.fontDescriptor
        let monospacedDescriptor = roundedDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier:
                    kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier:
                    kMonospacedNumbersSelector
            ]]
        ])
        let font = try XCTUnwrap(NSFont(
            descriptor: monospacedDescriptor,
            size: JoyRowLayout.statusFontSize
        ))
        let label = JoyStatusText.label(
            for: .finished(duration: 999 * 60 + 59),
            now: Date()
        )
        let labelWidth = (label as NSString).size(
            withAttributes: [.font: font]
        ).width

        XCTAssertEqual(JoyRowLayout.statusLabelWidth, 79)
        XCTAssertLessThanOrEqual(labelWidth, JoyRowLayout.statusLabelWidth)
    }

    func testStatusDurationsAlwaysUseTotalMinutesAndSeconds() {
        XCTAssertEqual(JoyStatusText.duration(59 * 60 + 59), "59:59")
        XCTAssertEqual(JoyStatusText.duration(3_600 + 46 * 60), "106:00")
        XCTAssertEqual(JoyStatusText.duration(2 * 3_600 + 5 * 60 + 7), "125:07")
        XCTAssertEqual(JoyStatusText.duration(100 * 3_600), "6000:00")
    }

    func testCheckingStatusUsesNeutralProgressCopy() {
        XCTAssertEqual(
            JoyStatusText.label(for: .checking, now: Date()),
            "Checking"
        )
    }

    func testOnlyRunningToFinishedProducesSuccessPulse() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            JoyTerminalPulse.transition(
                from: .running(startedAt: startedAt),
                to: .finished(duration: 8)
            ),
            .success
        )
        XCTAssertNil(
            JoyTerminalPulse.transition(
                from: .idle,
                to: .finished(duration: 8)
            )
        )
    }

    func testOnlyRunningToFailedProducesFailurePulse() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            JoyTerminalPulse.transition(
                from: .running(startedAt: startedAt),
                to: .failed
            ),
            .failure
        )
        XCTAssertNil(
            JoyTerminalPulse.transition(
                from: .closed,
                to: .failed
            )
        )
        XCTAssertNil(
            JoyTerminalPulse.transition(
                from: .running(startedAt: startedAt),
                to: .running(startedAt: startedAt)
            )
        )
    }

    @MainActor
    func testConfiguredRowsRenderMatchingSpacedDotsForChatAndCodex() throws {
        let suiteName = "JoyRowPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let chatLink = "https://chatgpt.com/c/6a55b1c2-9012-43f5-9237-cf773b000000"
        let codexLink = "codex://threads/019f5956-db8f-7b82-a0ea-701c8a000000"
        let store = MonitorStore(userDefaults: defaults)
        store.slots = [
            ChatSlot(id: 0, url: chatLink),
            ChatSlot(id: 1, url: codexLink),
            ChatSlot(id: 2, url: "")
        ]

        let hostingView = NSHostingView(rootView: JoyView(store: store))
        hostingView.frame = NSRect(
            origin: .zero,
            size: JoyPanelLayout.contentSize
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let displayedTextByLink = Dictionary(
            uniqueKeysWithValues: descendants(of: hostingView)
                .compactMap { $0 as? JoyNativeTextField }
                .filter { !$0.fullText.isEmpty }
                .map { ($0.fullText, $0.stringValue) }
        )

        XCTAssertEqual(displayedTextByLink[chatLink], "Chat \u{00B7} 000000")
        XCTAssertEqual(displayedTextByLink[codexLink], "Codex \u{00B7} 000000")
        withExtendedLifetime(window) {}
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}

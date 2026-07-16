import AppKit
import CoreText
import Foundation
import SwiftUI
import XCTest
@testable import Joy

final class JoyRowPresentationTests: XCTestCase {
    func testPanelUsesThreeRowThreeTwoFootprint() {
        XCTAssertEqual(JoyPanelLayout.frameSize.height, 178)
        XCTAssertEqual(JoyPanelLayout.frameSize.width, 267)
        XCTAssertEqual(JoyPanelLayout.contentSize.height, 166)
        XCTAssertEqual(
            JoyPanelLayout.frameSize.width / JoyPanelLayout.frameSize.height,
            3 / 2
        )
        XCTAssertEqual(
            JoyPanelLayout.frameSize.width * 2,
            JoyPanelLayout.frameSize.height * 3
        )
    }

    func testOuterMarginsExactlyMatchInterRowSpacing() {
        XCTAssertEqual(JoyRowLayout.rowSpacing, 6)
        XCTAssertEqual(
            JoyRowLayout.outerMargin,
            JoyRowLayout.rowSpacing
        )
        let rowWidth = JoyPanelLayout.frameSize.width
            - (2 * JoyRowLayout.outerMargin)
        let previousRowWidth: CGFloat = 276 - (2 * 10)
        XCTAssertEqual(rowWidth, 255)
        XCTAssertLessThanOrEqual(rowWidth, previousRowWidth)
    }

    @MainActor
    func testRenderedPanelPreservesTitlebarAndUsesOneSpacingUnit() throws {
        _ = NSApplication.shared
        let suiteName = "JoyRowPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MonitorStore(userDefaults: defaults)
        store.slots = [
            ChatSlot(
                id: 0,
                url: "https://chatgpt.com/c/6a55b1c2-9012-43f5-9237-cf773b000000"
            ),
            ChatSlot(
                id: 1,
                url: "codex://threads/019f5956-db8f-7b82-a0ea-701c8a000000"
            ),
            ChatSlot(
                id: 2,
                url: "codex://threads/019f5956-db8f-7b82-a0ea-701c8a000001"
            )
        ]
        let controller = JoyPanelController(store: store)
        let panel = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(panel.contentView)
        let originalStyleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .fullSizeContentView,
            .nonactivatingPanel
        ]
        let originalPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 274, height: 172),
            styleMask: originalStyleMask,
            backing: .buffered,
            defer: false
        )
        originalPanel.setFrame(
            NSRect(x: 0, y: 0, width: 276, height: 184),
            display: false
        )
        originalPanel.titleVisibility = .hidden
        originalPanel.titlebarAppearsTransparent = true
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let rowFrames = descendants(of: contentView)
            .compactMap { view -> NSRect? in
                guard view is JoyActiveHoverView else { return nil }
                let frame = contentView.convert(view.bounds, from: view)
                return frame.width > contentView.bounds.width / 2
                    ? frame
                    : nil
            }
            .sorted { $0.minY < $1.minY }
        let textFieldFrames = descendants(of: contentView)
            .compactMap { view -> NSRect? in
                guard view is JoyNativeTextField else { return nil }
                return contentView.convert(view.bounds, from: view)
            }
            .sorted { $0.minY < $1.minY }

        XCTAssertEqual(panel.frame.size, JoyPanelLayout.frameSize)
        XCTAssertEqual(panel.minSize, JoyPanelLayout.frameSize)
        XCTAssertEqual(panel.maxSize, JoyPanelLayout.frameSize)
        XCTAssertEqual(panel.styleMask, originalStyleMask)
        XCTAssertEqual(panel.titleVisibility, originalPanel.titleVisibility)
        XCTAssertEqual(
            panel.titlebarAppearsTransparent,
            originalPanel.titlebarAppearsTransparent
        )
        let originalTitlebarDepth = originalPanel.frame.height
            - originalPanel.contentLayoutRect.height
        XCTAssertEqual(
            panel.frame.height - panel.contentLayoutRect.height,
            originalTitlebarDepth,
            accuracy: 0.01
        )
        XCTAssertEqual(rowFrames.count, 3)
        XCTAssertEqual(textFieldFrames.count, 3)

        for kind in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            let button = try XCTUnwrap(panel.standardWindowButton(kind))
            let originalButton = try XCTUnwrap(
                originalPanel.standardWindowButton(kind)
            )
            XCTAssertEqual(button.frame, originalButton.frame)
        }

        for frame in rowFrames {
            XCTAssertEqual(
                frame.minX,
                JoyRowLayout.rowSpacing,
                accuracy: 0.01
            )
            XCTAssertEqual(
                contentView.bounds.width - frame.maxX,
                JoyRowLayout.rowSpacing,
                accuracy: 0.01
            )
            XCTAssertEqual(frame.height, JoyRowLayout.height, accuracy: 0.01)
        }
        for (lower, upper) in zip(rowFrames, rowFrames.dropFirst()) {
            XCTAssertEqual(
                upper.minY - lower.maxY,
                JoyRowLayout.rowSpacing,
                accuracy: 0.01
            )
        }
        let visuallyTopRow = try XCTUnwrap(rowFrames.first)
        XCTAssertEqual(
            visuallyTopRow.minY,
            originalTitlebarDepth,
            accuracy: 0.01
        )
        let visuallyBottomRow = try XCTUnwrap(rowFrames.last)
        XCTAssertEqual(
            contentView.bounds.height - visuallyBottomRow.maxY,
            JoyRowLayout.rowSpacing,
            accuracy: 0.01
        )
        for frame in textFieldFrames {
            XCTAssertEqual(frame.width, 111, accuracy: 0.01)
            XCTAssertLessThanOrEqual(frame.width, 112)
        }
        withExtendedLifetime(controller) {}
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
        let statusLabelWidth = JoyRowLayout.statusPillWidth
            - (2 * JoyRowLayout.statusContentInset)
            - JoyRowLayout.statusIconWidth
            - JoyRowLayout.statusContentSpacing

        XCTAssertEqual(statusLabelWidth, 79)
        XCTAssertLessThanOrEqual(labelWidth, statusLabelWidth)
    }

    func testStatusDurationsAlwaysUseTotalMinutesAndSeconds() {
        XCTAssertEqual(JoyStatusText.duration(59 * 60 + 59), "59:59")
        XCTAssertEqual(JoyStatusText.duration(3_600 + 46 * 60), "106:00")
        XCTAssertEqual(JoyStatusText.duration(2 * 3_600 + 5 * 60 + 7), "125:07")
        XCTAssertEqual(JoyStatusText.duration(100 * 3_600), "6000:00")
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

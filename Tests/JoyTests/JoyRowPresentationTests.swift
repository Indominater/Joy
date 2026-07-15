import Foundation
import XCTest
@testable import Joy

final class JoyRowPresentationTests: XCTestCase {
    func testPanelUsesThreeRowThreeTwoFootprint() {
        XCTAssertEqual(JoyPanelLayout.frameSize.height, 176)
        XCTAssertEqual(JoyPanelLayout.frameSize.width, 264)
        XCTAssertEqual(JoyPanelLayout.contentSize.height, 164)
        XCTAssertEqual(
            JoyPanelLayout.frameSize.width / JoyPanelLayout.frameSize.height,
            3 / 2
        )
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
}

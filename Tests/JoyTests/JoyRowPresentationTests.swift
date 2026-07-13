import Foundation
import XCTest
@testable import Joy

final class JoyRowPresentationTests: XCTestCase {
    func testPanelUsesHeightPreservingThreeTwoFootprint() {
        XCTAssertEqual(JoyPanelLayout.frameSize.height, 224)
        XCTAssertEqual(JoyPanelLayout.frameSize.width, 336)
        XCTAssertEqual(JoyPanelLayout.contentSize.height, 212)
    }

    func testStatusDurationsStayCompactInsideFixedCapsule() {
        XCTAssertEqual(JoyStatusText.duration(59 * 60 + 59), "59:59")
        XCTAssertEqual(JoyStatusText.duration(2 * 3_600 + 5 * 60), "2h05m")
        XCTAssertEqual(JoyStatusText.duration(100 * 3_600), "99h+")
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

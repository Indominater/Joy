import Foundation
import XCTest
@testable import Joy

final class ChatGPTRuntimeReducerTests: XCTestCase {
    private let url = "https://chatgpt.com/c/conversation"
    private let start = Date(timeIntervalSince1970: 1_000)

    func testContinuousRunningKeepsOriginalStartAcrossPageInstanceChange() {
        var beforeReload = transition(.running, page: "page-a", at: start)
        for second in 1...49 {
            beforeReload = transition(
                .running,
                page: "page-a",
                at: start.addingTimeInterval(TimeInterval(second)),
                previous: beforeReload
            )
        }
        let second = transition(
            .running,
            page: "page-b",
            at: start.addingTimeInterval(50),
            previous: beforeReload
        )

        XCTAssertEqual(runningStart(second.state), start)
    }

    func testTransientIdleDoesNotResetActiveRun() {
        let first = transition(.running, page: "page-a", at: start)
        let beforeIdle = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(8),
            previous: first
        )
        let idle = transition(
            .idle,
            page: "page-a",
            at: start.addingTimeInterval(10),
            previous: beforeIdle
        )
        let resumed = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(11),
            previous: idle
        )

        XCTAssertEqual(runningStart(idle.state), start)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testShortProbeInterruptionDoesNotResetActiveRun() {
        let first = transition(.running, page: "page-a", at: start)
        let unavailable = ChatGPTRuntimeReducer.interrupted(
            state: .failed,
            previous: first,
            observedAt: start.addingTimeInterval(1)
        )
        let resumed = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(2),
            previous: unavailable
        )

        XCTAssertEqual(unavailable.state, .failed)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testSingleMissingTabSampleDoesNotChangeVisibleRun() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: nil,
            response: nil,
            at: start
        )
        let missing = ChatGPTRuntimeReducer.missing(
            previous: first,
            observedAt: start.addingTimeInterval(10)
        )
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: nil,
            response: nil,
            at: start.addingTimeInterval(11),
            previous: missing
        )

        XCTAssertEqual(runningStart(missing.state), start)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testMissingSampleDoesNotResurrectFailedInterruption() {
        let first = transition(.running, page: "page-a", at: start)
        let unavailable = ChatGPTRuntimeReducer.interrupted(
            state: .failed,
            previous: first,
            observedAt: start.addingTimeInterval(1)
        )
        let missing = ChatGPTRuntimeReducer.missing(
            previous: unavailable,
            observedAt: start.addingTimeInterval(2)
        )

        XCTAssertEqual(missing.state, .closed)
        XCTAssertNil(missing.activeRunStartedAt)
    }

    func testSustainedMissingTabSampleBecomesClosed() {
        let first = transition(.running, page: "page-a", at: start)
        let transientMissing = ChatGPTRuntimeReducer.missing(
            previous: first,
            observedAt: start.addingTimeInterval(10)
        )
        let confirmedMissing = ChatGPTRuntimeReducer.missing(
            previous: transientMissing,
            observedAt: start.addingTimeInterval(20)
        )
        let nextRunAt = start.addingTimeInterval(21)
        let nextRun = transition(
            .running,
            page: "page-a",
            at: nextRunAt,
            previous: confirmedMissing
        )

        XCTAssertEqual(runningStart(transientMissing.state), start)
        XCTAssertEqual(confirmedMissing.state, .closed)
        XCTAssertNil(confirmedMissing.activeRunStartedAt)
        XCTAssertEqual(runningStart(nextRun.state), nextRunAt)
    }

    func testRealSampleResetsMissingConfirmation() {
        let first = transition(.running, page: "page-a", at: start)
        let firstMissing = ChatGPTRuntimeReducer.missing(
            previous: first,
            observedAt: start.addingTimeInterval(1)
        )
        let recovered = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(2),
            previous: firstMissing
        )
        let laterMissing = ChatGPTRuntimeReducer.missing(
            previous: recovered,
            observedAt: start.addingTimeInterval(3)
        )

        XCTAssertEqual(runningStart(laterMissing.state), start)
        XCTAssertEqual(laterMissing.consecutiveMissingSamples, 1)
    }

    func testSustainedPageFailureEndsRun() {
        let first = transition(.running, page: "page-a", at: start)
        let firstFailureAt = start.addingTimeInterval(1)
        let transientFailure = transition(
            .failed,
            page: "page-a",
            at: firstFailureAt,
            previous: first
        )
        XCTAssertEqual(runningStart(transientFailure.state), start)

        let failed = transition(
            .failed,
            page: "page-a",
            at: firstFailureAt.addingTimeInterval(
                ChatGPTRuntimeReducer.terminalConfirmationDelay
            ),
            previous: transientFailure
        )
        let retryAt = start.addingTimeInterval(4)
        let retry = transition(
            .running,
            page: "page-a",
            at: retryAt,
            previous: failed
        )

        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(runningStart(retry.state), retryAt)
    }

    func testNewResponseDuringIdleDebounceGetsNewStart() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start
        )
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start.addingTimeInterval(1),
            previous: first
        )
        let nextRunAt = start.addingTimeInterval(2)
        let nextRun = transition(
            .running,
            page: "page-a",
            prompt: "prompt-b",
            response: nil,
            at: nextRunAt,
            previous: idle
        )

        XCTAssertEqual(runningStart(nextRun.state), nextRunAt)
    }

    func testRegeneratedResponseGetsNewStartWithoutSampledIdle() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start
        )
        let nextRunAt = start.addingTimeInterval(1)
        let nextRun = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-b",
            at: nextRunAt,
            previous: first
        )

        XCTAssertEqual(runningStart(nextRun.state), nextRunAt)
    }

    func testAssistantIdentityAppearingDoesNotResetActiveRun() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: nil,
            at: start
        )
        let identified = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start.addingTimeInterval(1),
            previous: first
        )

        XCTAssertEqual(runningStart(identified.state), start)
        XCTAssertEqual(identified.responseInstance, "response-a")
    }

    func testAlternatingTerminalSamplesStillFinishRun() {
        let first = transition(.running, page: "page-a", at: start)
        let beforeTerminal = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(8),
            previous: first
        )
        let idle = transition(
            .idle,
            page: "page-a",
            at: start.addingTimeInterval(9),
            previous: beforeTerminal
        )
        let failed = transition(
            .failed,
            page: "page-a",
            at: start.addingTimeInterval(10),
            previous: idle
        )
        let finished = transition(
            .idle,
            page: "page-a",
            at: start.addingTimeInterval(11),
            previous: failed
        )

        XCTAssertEqual(runningStart(idle.state), start)
        XCTAssertEqual(runningStart(failed.state), start)
        XCTAssertEqual(finished.state, .finished(duration: 9))
    }

    func testLongProbeInterruptionKeepsKnownResponseStart() {
        let first = transition(.running, page: "page-a", at: start)
        let unavailable = ChatGPTRuntimeReducer.interrupted(
            state: .failed,
            previous: first,
            observedAt: start.addingTimeInterval(1)
        )
        let resumedAt = start.addingTimeInterval(
            ChatGPTRuntimeReducer.continuityGrace + 1
        )
        let resumed = transition(
            .running,
            page: "page-a",
            at: resumedAt,
            previous: unavailable
        )

        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testLongProbeInterruptionStartsNewRunWhenIdentityIsAmbiguous() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: nil,
            at: start
        )
        let unavailable = ChatGPTRuntimeReducer.interrupted(
            state: .failed,
            previous: first,
            observedAt: start.addingTimeInterval(1)
        )
        let resumedAt = start.addingTimeInterval(
            ChatGPTRuntimeReducer.continuityGrace + 1
        )
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: nil,
            at: resumedAt,
            previous: unavailable
        )

        XCTAssertEqual(runningStart(resumed.state), resumedAt)
    }

    func testSustainedIdleFinishesAtFirstIdleSample() {
        let first = transition(.running, page: "page-a", at: start)
        let beforeIdle = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(8),
            previous: first
        )
        let firstIdleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            at: firstIdleAt,
            previous: beforeIdle
        )
        let finished = transition(
            .idle,
            page: "page-a",
            at: firstIdleAt.addingTimeInterval(
                ChatGPTRuntimeReducer.terminalConfirmationDelay
            ),
            previous: idle
        )

        guard case .finished(let duration) = finished.state else {
            return XCTFail("Expected a finished runtime")
        }
        XCTAssertEqual(duration, 10)
        XCTAssertNil(finished.activeRunStartedAt)
    }

    func testRunAfterConfirmedFinishGetsNewStart() {
        let first = transition(.running, page: "page-a", at: start)
        let beforeIdle = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(8),
            previous: first
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            at: idleAt,
            previous: beforeIdle
        )
        let finished = transition(
            .idle,
            page: "page-a",
            at: idleAt.addingTimeInterval(
                ChatGPTRuntimeReducer.terminalConfirmationDelay
            ),
            previous: idle
        )
        let nextRunAt = start.addingTimeInterval(20)
        let nextRun = transition(
            .running,
            page: "page-a",
            at: nextRunAt,
            previous: finished
        )

        XCTAssertEqual(runningStart(nextRun.state), nextRunAt)
    }

    func testStrongestSamplesPreferTrackedPageWhenPrioritiesTie() {
        let samples = [
            sample(.running, page: "page-b"),
            sample(.running, page: "page-a")
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredURLs: [url],
            preferredPageInstances: [url: "page-a"]
        )

        XCTAssertEqual(strongest[url]?.pageInstance, "page-a")
    }

    func testStrongestSamplesPreferRunningOverIdle() {
        let samples = [
            sample(.idle, page: "page-a"),
            sample(.running, page: "page-b")
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredURLs: [url],
            preferredPageInstances: [url: "page-a"]
        )

        XCTAssertEqual(strongest[url]?.status, .running)
    }

    private func transition(
        _ status: ChromeProbeStatus,
        page: String,
        prompt: String? = "prompt-a",
        response: String? = "response-a",
        at date: Date,
        previous: MonitorObservation? = nil
    ) -> MonitorObservation {
        ChatGPTRuntimeReducer.transition(
            sample: sample(
                status,
                page: page,
                prompt: prompt,
                response: response
            ),
            previous: previous,
            observedAt: date
        )
    }

    private func sample(
        _ status: ChromeProbeStatus,
        page: String,
        prompt: String? = "prompt-a",
        response: String? = "response-a"
    ) -> ChromeTabSample {
        ChromeTabSample(
            url: url,
            status: status,
            pageInstance: page,
            promptInstance: prompt,
            responseInstance: response
        )
    }

    private func runningStart(_ state: ChatState) -> Date? {
        guard case .running(let startedAt) = state else { return nil }
        return startedAt
    }
}

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

    func testReloadedDOMIdentityDoesNotResetRecentActiveRun() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start
        )
        let rebuilding = transition(
            .running,
            page: "page-b",
            prompt: nil,
            response: nil,
            at: start.addingTimeInterval(1),
            previous: first
        )
        let rebuilt = transition(
            .running,
            page: "page-b",
            prompt: "prompt-a",
            response: "response-b",
            at: start.addingTimeInterval(2),
            previous: rebuilding
        )

        XCTAssertEqual(runningStart(rebuilding.state), start)
        XCTAssertEqual(runningStart(rebuilt.state), start)
    }

    func testPromptIdentityTemporarilyMissingDoesNotResetRecentActiveRun() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let fallback = transition(
            .running,
            page: "page-b",
            prompt: nil,
            response: nil,
            at: start.addingTimeInterval(1),
            previous: first
        )
        let restored = transition(
            .running,
            page: "page-b",
            prompt: "turn-slot:prompt-a",
            response: "message:response-b",
            at: start.addingTimeInterval(2),
            previous: fallback
        )

        XCTAssertEqual(runningStart(fallback.state), start)
        XCTAssertEqual(fallback.promptInstance, "turn-slot:prompt-a")
        XCTAssertEqual(runningStart(restored.state), start)
    }

    func testNewPromptStillResetsAfterTemporarilyMissingIdentity() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let transitional = transition(
            .running,
            page: "page-b",
            prompt: nil,
            response: nil,
            at: start.addingTimeInterval(1),
            previous: first
        )
        let newRunAt = start.addingTimeInterval(2)
        let newRun = transition(
            .running,
            page: "page-b",
            prompt: "turn-slot:prompt-b",
            response: "message:response-b",
            at: newRunAt,
            previous: transitional
        )

        XCTAssertEqual(runningStart(transitional.state), start)
        XCTAssertEqual(transitional.promptInstance, "turn-slot:prompt-a")
        XCTAssertEqual(runningStart(newRun.state), newRunAt)
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

    func testAssistantPhaseChangeDuringIdleDebounceKeepsOriginalStart() {
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
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-b",
            at: start.addingTimeInterval(2),
            previous: idle
        )

        XCTAssertEqual(runningStart(idle.state), start)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testShortProbeInterruptionDoesNotResetActiveRun() {
        let first = transition(.running, page: "page-a", at: start)
        let unavailable = ChatGPTRuntimeReducer.interrupted(
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
            observedAt: start.addingTimeInterval(1)
        )
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: nil,
            response: nil,
            at: start.addingTimeInterval(2),
            previous: missing
        )

        XCTAssertEqual(runningStart(missing.state), start)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testFirstMissingSampleAfterGraceClearsContinuity() {
        let first = transition(.running, page: "page-a", at: start)
        let missingAt = start.addingTimeInterval(
            ChatGPTRuntimeReducer.continuityGrace + 1
        )
        let missing = ChatGPTRuntimeReducer.missing(
            previous: first,
            observedAt: missingAt
        )
        let resumedAt = missingAt.addingTimeInterval(1)
        let resumed = transition(
            .running,
            page: "page-a",
            at: resumedAt,
            previous: missing
        )

        XCTAssertEqual(missing.state, .closed)
        XCTAssertNil(missing.runContinuity)
        XCTAssertEqual(runningStart(resumed.state), resumedAt)
    }

    func testMissingAfterInterruptionDoesNotFlashClosedWithinGrace() {
        let first = transition(.running, page: "page-a", at: start)
        let partialScan = ChatGPTRuntimeReducer.absent(
            previous: first,
            observedAt: start.addingTimeInterval(1),
            enumerationIsComplete: false
        )
        let completeMissing = ChatGPTRuntimeReducer.absent(
            previous: partialScan,
            observedAt: start.addingTimeInterval(2),
            enumerationIsComplete: true
        )
        let resumed = transition(
            .running,
            page: "page-a",
            at: start.addingTimeInterval(3),
            previous: completeMissing
        )

        XCTAssertEqual(partialScan.state, .failed)
        XCTAssertEqual(completeMissing.state, .failed)
        XCTAssertNotNil(completeMissing.runContinuity)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testMissingAfterInterruptionBecomesClosedAfterGrace() {
        let first = transition(.running, page: "page-a", at: start)
        let partialScan = ChatGPTRuntimeReducer.absent(
            previous: first,
            observedAt: start.addingTimeInterval(1),
            enumerationIsComplete: false
        )
        let missing = ChatGPTRuntimeReducer.absent(
            previous: partialScan,
            observedAt: start.addingTimeInterval(
                ChatGPTRuntimeReducer.continuityGrace + 1
            ),
            enumerationIsComplete: true
        )

        XCTAssertEqual(missing.state, .closed)
        XCTAssertNil(missing.runContinuity)
    }

    func testUnavailablePresentTabDoesNotBecomeClosedOnNextOmission() {
        let unavailable = transition(
            .unavailable,
            page: "",
            prompt: nil,
            response: nil,
            at: start
        )
        let transientMissing = ChatGPTRuntimeReducer.absent(
            previous: unavailable,
            observedAt: start.addingTimeInterval(1),
            enumerationIsComplete: true
        )
        let sustainedMissing = ChatGPTRuntimeReducer.absent(
            previous: transientMissing,
            observedAt: start.addingTimeInterval(
                ChatGPTRuntimeReducer.continuityGrace + 1
            ),
            enumerationIsComplete: true
        )

        XCTAssertEqual(unavailable.state, .failed)
        XCTAssertEqual(unavailable.lastPresentAt, start)
        XCTAssertEqual(transientMissing.state, .failed)
        XCTAssertEqual(sustainedMissing.state, .closed)
    }

    func testPresentedStateUsesCheckingWithoutEvidenceAndFailedWhenStale() {
        let running = transition(.running, page: "page-a", at: start)

        XCTAssertEqual(
            ChatGPTRuntimeReducer.presentedState(for: nil, now: start),
            .checking
        )
        XCTAssertEqual(
            ChatGPTRuntimeReducer.presentedState(
                for: running,
                now: start.addingTimeInterval(
                    ChatGPTRuntimeReducer.continuityGrace - 0.1
                )
            ),
            running.state
        )
        XCTAssertEqual(
            ChatGPTRuntimeReducer.presentedState(
                for: running,
                now: start.addingTimeInterval(
                    ChatGPTRuntimeReducer.continuityGrace
                )
            ),
            .failed
        )
    }

    func testRepeatedMissingSamplesWithinGraceKeepActiveRun() {
        var observation = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start
        )

        for second in 1...3 {
            observation = ChatGPTRuntimeReducer.missing(
                previous: observation,
                observedAt: start.addingTimeInterval(TimeInterval(second))
            )
            XCTAssertEqual(runningStart(observation.state), start)
        }

        let resumed = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-b",
            at: start.addingTimeInterval(4),
            previous: observation
        )

        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testPerTabProbeFailureKeepsRunContinuity() {
        let first = transition(.running, page: "page-a", at: start)
        let unavailable = transition(
            .unavailable,
            page: "",
            prompt: nil,
            response: nil,
            at: start.addingTimeInterval(1),
            previous: first
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

    func testSustainedMissingTabSampleBecomesClosed() {
        let first = transition(.running, page: "page-a", at: start)
        let transientMissing = ChatGPTRuntimeReducer.missing(
            previous: first,
            observedAt: start.addingTimeInterval(1)
        )
        let confirmedMissing = ChatGPTRuntimeReducer.missing(
            previous: transientMissing,
            observedAt: start.addingTimeInterval(
                ChatGPTRuntimeReducer.continuityGrace + 1
            )
        )
        let nextRunAt = start.addingTimeInterval(
            ChatGPTRuntimeReducer.continuityGrace + 2
        )
        let nextRun = transition(
            .running,
            page: "page-a",
            at: nextRunAt,
            previous: confirmedMissing
        )

        XCTAssertEqual(runningStart(transientMissing.state), start)
        XCTAssertEqual(confirmedMissing.state, .closed)
        XCTAssertNil(confirmedMissing.runContinuity)
        XCTAssertEqual(runningStart(nextRun.state), nextRunAt)
    }

    func testRealSampleRefreshesMissingContinuity() {
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

    func testAssistantPhaseIdentityChangeDoesNotResetUninterruptedRun() {
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

        XCTAssertEqual(runningStart(nextRun.state), start)
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
        XCTAssertNotNil(finished.runContinuity)
    }

    func testRunResumingSoonAfterConfirmedIdleKeepsOriginalStart() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start
        )
        let firstIdleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: firstIdleAt,
            previous: first
        )
        let finishedAt = firstIdleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: finishedAt,
            previous: idle
        )
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: finishedAt.addingTimeInterval(1),
            previous: finished
        )

        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testAssistantPhaseChangeAfterConfirmedIdleKeepsOriginalStart() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: start
        )
        let firstIdleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: firstIdleAt,
            previous: first
        )
        let finishedAt = firstIdleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-a",
            at: finishedAt,
            previous: idle
        )
        let nextRunAt = finishedAt.addingTimeInterval(1)
        let nextRun = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "response-b",
            at: nextRunAt,
            previous: finished
        )

        XCTAssertEqual(runningStart(nextRun.state), start)
    }

    func testUnknownFinishedRecoveryReturnsToActiveContinuity() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: first
        )
        let finishedAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt,
            previous: idle
        )
        let unidentified = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: nil,
            at: finishedAt.addingTimeInterval(1),
            previous: finished
        )
        let identifiedAt = finishedAt.addingTimeInterval(2)
        let identified = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-b",
            at: identifiedAt,
            previous: unidentified
        )

        XCTAssertEqual(runningStart(unidentified.state), start)
        XCTAssertNil(unidentified.runContinuity?.recoverableUntil)
        XCTAssertEqual(runningStart(identified.state), start)
    }

    func testContinuousRunningWithoutAssistantIdentityOutlivesRecoveryLease() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: first
        )
        let finishedAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt,
            previous: idle
        )
        var continued = finished
        for second in 1...(Int(ChatGPTRuntimeReducer.continuityGrace) + 2) {
            continued = transition(
                .running,
                page: "page-a",
                prompt: "turn-slot:prompt-a",
                response: nil,
                at: finishedAt.addingTimeInterval(TimeInterval(second)),
                previous: continued
            )
            XCTAssertEqual(runningStart(continued.state), start)
            XCTAssertNil(continued.runContinuity?.recoverableUntil)
        }

        let identifiedAt = finishedAt.addingTimeInterval(
            ChatGPTRuntimeReducer.continuityGrace + 3
        )
        let identified = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-b",
            at: identifiedAt,
            previous: continued
        )

        XCTAssertEqual(runningStart(identified.state), start)
    }

    func testNewPromptAfterUnknownFinishedRecoveryStartsNewRun() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: first
        )
        let finishedAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt,
            previous: idle
        )
        let recovered = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: nil,
            at: finishedAt.addingTimeInterval(1),
            previous: finished
        )
        let newRunAt = finishedAt.addingTimeInterval(2)
        let newRun = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-b",
            response: "message:response-b",
            at: newRunAt,
            previous: recovered
        )

        XCTAssertEqual(runningStart(recovered.state), start)
        XCTAssertEqual(runningStart(newRun.state), newRunAt)
    }

    func testIdleReloadPreservesRecentFinishedRecovery() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: first
        )
        let finishedAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt,
            previous: idle
        )
        let reloaded = transition(
            .idle,
            page: "page-b",
            prompt: nil,
            response: nil,
            at: finishedAt.addingTimeInterval(1),
            previous: finished
        )
        let resumed = transition(
            .running,
            page: "page-b",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt.addingTimeInterval(2),
            previous: reloaded
        )

        XCTAssertEqual(reloaded.state, finished.state)
        XCTAssertNotNil(reloaded.runContinuity)
        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testFinishedRecoverySurvivesTransientMissingTab() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: first
        )
        let finishedAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt,
            previous: idle
        )
        let transientMissing = ChatGPTRuntimeReducer.missing(
            previous: finished,
            observedAt: finishedAt.addingTimeInterval(1)
        )
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: finishedAt.addingTimeInterval(2),
            previous: transientMissing
        )
        let sustainedMissing = ChatGPTRuntimeReducer.missing(
            previous: finished,
            observedAt: finishedAt.addingTimeInterval(
                ChatGPTRuntimeReducer.continuityGrace + 1
            )
        )

        XCTAssertEqual(transientMissing.state, finished.state)
        XCTAssertEqual(runningStart(resumed.state), start)
        XCTAssertEqual(sustainedMissing.state, .closed)
    }

    func testRunAfterConfirmedFinishGetsNewStart() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start
        )
        let beforeIdle = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: start.addingTimeInterval(8),
            previous: first
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: beforeIdle
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-a",
            at: idleAt.addingTimeInterval(
                ChatGPTRuntimeReducer.terminalConfirmationDelay
            ),
            previous: idle
        )
        let nextRunAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
                + ChatGPTRuntimeReducer.continuityGrace
                + 1
        )
        let nextRun = transition(
            .running,
            page: "page-a",
            prompt: "turn-slot:prompt-a",
            response: "message:response-b",
            at: nextRunAt,
            previous: finished
        )

        XCTAssertEqual(runningStart(nextRun.state), nextRunAt)
    }

    func testExactResponseIdentityCanResumeAfterLongControlGap() {
        let first = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "message:response-a",
            at: start
        )
        let idleAt = start.addingTimeInterval(10)
        let idle = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "message:response-a",
            at: idleAt,
            previous: first
        )
        let finishedAt = idleAt.addingTimeInterval(
            ChatGPTRuntimeReducer.terminalConfirmationDelay
        )
        let finished = transition(
            .idle,
            page: "page-a",
            prompt: "prompt-a",
            response: "message:response-a",
            at: finishedAt,
            previous: idle
        )
        let resumed = transition(
            .running,
            page: "page-a",
            prompt: "prompt-a",
            response: "message:response-a",
            at: finishedAt.addingTimeInterval(
                ChatGPTRuntimeReducer.continuityGrace + 20
            ),
            previous: finished
        )

        XCTAssertEqual(runningStart(resumed.state), start)
    }

    func testChromeParserRetainsPerTabProbeFailure() {
        let output = url
            + "|||JOY_FIELD|||unavailable::JOY::::JOY::::JOY::"
            + "|||JOY_RECORD|||"

        let samples = ChromeAppleEventsMonitor.parseSamples(output)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.url, url)
        XCTAssertEqual(samples.first?.status, .unavailable)
        XCTAssertEqual(samples.first?.pageInstance, "")
        XCTAssertNil(samples.first?.promptInstance)
        XCTAssertNil(samples.first?.responseInstance)
        XCTAssertNil(samples.first?.location)
    }

    func testChromeParserRetainsCachedTabLocation() {
        let output = url
            + "|||JOY_FIELD|||731"
            + "|||JOY_FIELD|||4"
            + "|||JOY_FIELD|||running::JOY::page-a::JOY::prompt-a::JOY::response-a"
            + "|||JOY_RECORD|||"

        let samples = ChromeAppleEventsMonitor.parseSamples(output)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(
            samples.first?.location,
            ChromeTabLocation(windowID: 731, tabIndex: 4)
        )
    }

    func testPIDSpecificProbeRetainsOwningChromeProcess() throws {
        let location = ChromeTabLocation(
            windowID: 613217623,
            tabIndex: 6,
            processID: 869
        )
        let sample = try XCTUnwrap(ChromeAppleEventsMonitor.parseProbe(
            url: url,
            probeValue: "running::JOY::page-a::JOY::prompt-a::JOY::response-a",
            location: location
        ))

        XCTAssertEqual(sample.status, .running)
        XCTAssertEqual(sample.location, location)
        XCTAssertEqual(sample.location?.processID, 869)
    }

    func testChromeParserMarksIncompleteEnumerationAsPartial() {
        let output = "__JOY_PARTIAL__|||JOY_RECORD|||"
            + url
            + "|||JOY_FIELD|||731"
            + "|||JOY_FIELD|||4"
            + "|||JOY_FIELD|||running::JOY::page-a::JOY::prompt-a::JOY::"
            + "|||JOY_RECORD|||"

        switch ChromeAppleEventsMonitor.parseOutput(output) {
        case .success(let samples, let isComplete):
            XCTAssertFalse(isComplete)
            XCTAssertEqual(samples.count, 1)
            XCTAssertEqual(samples.first?.status, .running)
        case .unavailable:
            XCTFail("Expected a partial Chrome enumeration")
        }
    }

    func testChromeParserKeepsPayloadWhenTabLocationIsUnavailable() {
        let output = url
            + "|||JOY_FIELD|||"
            + "|||JOY_FIELD|||"
            + "|||JOY_FIELD|||running::JOY::page-a::JOY::prompt-a::JOY::"
            + "|||JOY_RECORD|||"

        let samples = ChromeAppleEventsMonitor.parseSamples(output)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.status, .running)
        XCTAssertNil(samples.first?.location)
    }

    func testChromeParserTreatsDroppedRecordAsIncompleteEnumeration() {
        let output = url
            + "|||JOY_FIELD|||idle::JOY::page-a::JOY::::JOY::"
            + "|||JOY_RECORD|||malformed-record|||JOY_RECORD|||"

        switch ChromeAppleEventsMonitor.parseOutput(output) {
        case .success(let samples, let isComplete):
            XCTAssertFalse(isComplete)
            XCTAssertEqual(samples.count, 1)
        case .unavailable:
            XCTFail("Expected a partial Chrome enumeration")
        }
    }

    func testChromeParserIgnoresValidNonConversationRoutesForCompleteness() {
        let output = url
            + "|||JOY_FIELD|||idle::JOY::page-a::JOY::::JOY::"
            + "|||JOY_RECORD|||https://chatgpt.com/"
            + "|||JOY_FIELD|||unavailable::JOY::::JOY::::JOY::"
            + "|||JOY_RECORD|||"

        switch ChromeAppleEventsMonitor.parseOutput(output) {
        case .success(let samples, let isComplete):
            XCTAssertTrue(isComplete)
            XCTAssertEqual(samples.count, 1)
        case .unavailable:
            XCTFail("Expected a complete Chrome enumeration")
        }
    }

    func testStrongestSamplesPreferTrackedPageWhenPrioritiesTie() {
        let samples = [
            sample(.running, page: "page-b"),
            sample(.running, page: "page-a")
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredTargetKeys: [targetKey],
            preferredPageInstances: [targetKey: "page-a"]
        )

        XCTAssertEqual(strongest[targetKey]?.pageInstance, "page-a")
    }

    func testStrongestSamplesPreferRunningOverIdle() {
        let samples = [
            sample(.idle, page: "page-a"),
            sample(.running, page: "page-b")
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredTargetKeys: [targetKey],
            preferredPageInstances: [targetKey: "page-a"]
        )

        XCTAssertEqual(strongest[targetKey]?.status, .running)
    }

    func testStrongestSamplesPreferUnavailableOverDuplicateIdle() {
        let samples = [
            sample(.unavailable, page: ""),
            sample(.idle, page: "page-b")
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredTargetKeys: [targetKey],
            preferredPageInstances: [targetKey: "page-a"]
        )

        XCTAssertEqual(strongest[targetKey]?.status, .unavailable)
    }

    func testStrongestSamplesPreferTrackedFailureOverDuplicateUnavailable() {
        let samples = [
            sample(.unavailable, page: ""),
            sample(.failed, page: "page-a")
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredTargetKeys: [targetKey],
            preferredPageInstances: [targetKey: "page-a"]
        )

        XCTAssertEqual(strongest[targetKey]?.status, .failed)
        XCTAssertEqual(strongest[targetKey]?.pageInstance, "page-a")
    }

    func testConfiguredConversationMatchesRunningSampleAfterWrapperChange() {
        let conversationID = "6a234240-1ba8-832c-b452-46ceea131482"
        let configuredURL = "https://chatgpt.com/g/g-p-old/c/\(conversationID)"
        let liveURL = "https://chatgpt.com/g/g-p-new/c/\(conversationID)?tab=chats"
        let configuredKey = URLNormalizer.target(configuredURL)!.key
        let samples = [
            ChromeTabSample(
                url: URLNormalizer.normalizeChatGPT(liveURL)!,
                status: .running,
                pageInstance: "page-live",
                promptInstance: "turn-slot:prompt-a",
                responseInstance: nil,
                location: ChromeTabLocation(windowID: 731, tabIndex: 4)
            )
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredTargetKeys: [configuredKey],
            preferredPageInstances: [:]
        )

        XCTAssertEqual(strongest[configuredKey]?.status, .running)
        XCTAssertEqual(
            strongest[configuredKey]?.url,
            URLNormalizer.normalizeChatGPT(liveURL)
        )
    }

    func testDifferentConversationDoesNotMatchConfiguredTarget() {
        let configuredKey = URLNormalizer.target(
            "https://chatgpt.com/g/g-p-old/c/conversation-a"
        )!.key
        let samples = [
            ChromeTabSample(
                url: "https://chatgpt.com/g/g-p-new/c/conversation-b",
                status: .running,
                pageInstance: "page-live",
                promptInstance: nil,
                responseInstance: nil
            )
        ]

        let strongest = ChatGPTRuntimeReducer.strongestSamples(
            samples,
            configuredTargetKeys: [configuredKey],
            preferredPageInstances: [:]
        )

        XCTAssertNil(strongest[configuredKey])
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

    private var targetKey: String {
        URLNormalizer.target(url)!.key
    }
}

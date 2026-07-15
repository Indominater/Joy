import XCTest
@testable import Joy

final class ChromeTabFocusTests: XCTestCase {
    func testChromeCreationUsesScriptingDictionaryElementCodes() {
        XCTAssertEqual(
            ChromeScriptingBridgeFocus.tabElementCode,
            0x43725462 // "CrTb"
        )
        XCTAssertEqual(
            ChromeScriptingBridgeFocus.windowElementCode,
            0x6377696E // "cwin"
        )
    }

    func testMonitorSelectsForegroundChromeAndExcludesHeadlessMain() {
        let candidates = [
            ChromeProcessCandidate(
                processID: 869,
                isTerminated: false,
                activationPolicy: .regular
            ),
            ChromeProcessCandidate(
                processID: 29488,
                isTerminated: false,
                activationPolicy: .prohibited
            ),
            ChromeProcessCandidate(
                processID: 991,
                isTerminated: true,
                activationPolicy: .regular
            )
        ]

        XCTAssertEqual(
            ChromeProcessLocator.monitorableProcessIDs(from: candidates),
            [869]
        )
    }

    func testPIDSpecificFocusPrefersCachedListedProcess() {
        XCTAssertEqual(
            ChromeScriptingBridgeFocus.orderedProcessIDs(
                [869, 29488, 869],
                preferredProcessID: 29488
            ),
            [29488, 869]
        )
    }

    func testPIDSpecificFocusRejectsStaleOrUnlistedHint() {
        XCTAssertEqual(
            ChromeScriptingBridgeFocus.orderedProcessIDs(
                [869],
                preferredProcessID: 29488
            ),
            [869]
        )
        XCTAssertEqual(
            ChromeScriptingBridgeFocus.orderedProcessIDs(
                [869],
                preferredProcessID: nil
            ),
            [869]
        )
    }

    func testPIDSpecificFocusMatchesConversationIdentityAcrossWrappers() {
        let conversationID = "6a57dc1a-b640-83e8-b3a6-ec449dd2d0d7"
        let target = "https://chatgpt.com/c/\(conversationID)"
        let wrapped = "https://chatgpt.com/g/g-p-new/c/\(conversationID)"
            + "?tab=chats#response"

        XCTAssertTrue(ChromeScriptingBridgeFocus.matchesConversation(
            wrapped,
            targetURL: target
        ))
        XCTAssertFalse(ChromeScriptingBridgeFocus.matchesConversation(
            "https://chatgpt.com/c/\(conversationID)-other",
            targetURL: target
        ))
    }

    func testFocusRequiresStableVerifiedReadback() {
        var tracker = ChromeFocusSettleTracker(requiredConfirmations: 2)
        let verified = ChromeFocusSnapshot(
            isMinimized: false,
            isTargetFrontWindow: true,
            activeTabIndex: 7,
            appleEventFailed: false
        )

        XCTAssertFalse(tracker.observe(verified, targetTabIndex: 7))
        XCTAssertTrue(tracker.observe(verified, targetTabIndex: 7))
    }

    func testFocusReadbackResetsAfterChromeRestoresAnotherWindow() {
        var tracker = ChromeFocusSettleTracker(requiredConfirmations: 2)
        let verified = ChromeFocusSnapshot(
            isMinimized: false,
            isTargetFrontWindow: true,
            activeTabIndex: 3,
            appleEventFailed: false
        )
        let restoredOtherWindow = ChromeFocusSnapshot(
            isMinimized: false,
            isTargetFrontWindow: false,
            activeTabIndex: 3,
            appleEventFailed: false
        )

        XCTAssertFalse(tracker.observe(verified, targetTabIndex: 3))
        XCTAssertFalse(
            tracker.observe(restoredOtherWindow, targetTabIndex: 3)
        )
        XCTAssertFalse(tracker.observe(verified, targetTabIndex: 3))
        XCTAssertTrue(tracker.observe(verified, targetTabIndex: 3))
    }

    func testFocusRejectsMinimizedWrongTabAndAppleEventFailure() {
        let snapshots = [
            ChromeFocusSnapshot(
                isMinimized: true,
                isTargetFrontWindow: true,
                activeTabIndex: 5,
                appleEventFailed: false
            ),
            ChromeFocusSnapshot(
                isMinimized: false,
                isTargetFrontWindow: true,
                activeTabIndex: 4,
                appleEventFailed: false
            ),
            ChromeFocusSnapshot(
                isMinimized: false,
                isTargetFrontWindow: true,
                activeTabIndex: 5,
                appleEventFailed: true
            )
        ]

        for snapshot in snapshots {
            XCTAssertFalse(snapshot.confirms(targetTabIndex: 5))
        }
    }

    @MainActor
    func testFocusOrdersTargetBeforeActivationAndVerifiesAfterward() async {
        var steps: [String] = []

        let focused = await ChromeTabFocus.runFocusSequence(
            prepare: {
                steps.append("prepare")
                return true
            },
            activate: {
                steps.append("activate")
            },
            settle: {
                steps.append("settle")
            },
            verify: {
                steps.append("verify")
                return true
            }
        )

        XCTAssertTrue(focused)
        XCTAssertEqual(steps, ["prepare", "activate", "settle", "verify"])
    }

    @MainActor
    func testFocusDoesNotActivateWhenTargetCannotBePrepared() async {
        var didActivate = false

        let focused = await ChromeTabFocus.runFocusSequence(
            prepare: { false },
            activate: { didActivate = true },
            settle: {},
            verify: { true }
        )

        XCTAssertFalse(focused)
        XCTAssertFalse(didActivate)
    }
}

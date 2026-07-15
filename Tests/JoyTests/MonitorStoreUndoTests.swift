import AppKit
import Foundation
import XCTest
@testable import Joy

final class MonitorStoreUndoTests: XCTestCase {
    @MainActor
    func testStoreProvidesThreeRows() {
        withStore { store in
            XCTAssertEqual(store.slots.map(\.id), [0, 1, 2])
        }
    }

    @MainActor
    func testUndoRestoresOnlyNewestClearAndCannotRedo() {
        withStore { store in
            store.slots[0].url = "first-link"
            store.slots[1].url = "second-link"

            store.clearURL(for: 0)
            XCTAssertEqual(store.undoableClearSlotID, 0)
            store.clearURL(for: 1)

            XCTAssertEqual(store.slots[0].url, "")
            XCTAssertEqual(store.slots[1].url, "")
            XCTAssertEqual(store.undoableClearSlotID, 1)
            XCTAssertTrue(store.canUndoLastClear)
            XCTAssertTrue(store.undoLastClear())
            XCTAssertEqual(store.slots[0].url, "")
            XCTAssertEqual(store.slots[1].url, "second-link")
            XCTAssertNil(store.undoableClearSlotID)
            XCTAssertFalse(store.canUndoLastClear)
            XCTAssertFalse(store.undoLastClear())
        }
    }

    @MainActor
    func testPasteIntoClearedSlotInvalidatesUndoWithoutOverwriting() {
        withStore { store in
            store.slots[0].url = "deleted-link"

            store.clearURL(for: 0)
            store.updateURL(for: 0, to: "replacement-link")

            XCTAssertNil(store.undoableClearSlotID)
            XCTAssertFalse(store.canUndoLastClear)
            XCTAssertFalse(store.undoLastClear())
            XCTAssertEqual(store.slots[0].url, "replacement-link")
        }
    }

    @MainActor
    func testClearUndoExpiresAfterLifetime() async throws {
        try await withStore(clearUndoLifetime: .milliseconds(20)) { store in
            store.slots[0].url = "short-lived-link"
            store.clearURL(for: 0)
            XCTAssertTrue(store.canUndoLastClear)
            XCTAssertEqual(store.undoableClearSlotID, 0)

            try await Task.sleep(for: .milliseconds(80))

            XCTAssertFalse(store.canUndoLastClear)
            XCTAssertNil(store.undoableClearSlotID)
            XCTAssertFalse(store.undoLastClear())
            XCTAssertEqual(store.slots[0].url, "")
        }
    }

    @MainActor
    func testRowScopedUndoCannotConsumeANewerRowsClear() {
        withStore { store in
            store.slots[0].url = "first-link"
            store.slots[1].url = "second-link"

            store.clearURL(for: 0)
            store.clearURL(for: 1)

            XCTAssertFalse(store.undoLastClear(for: 0))
            XCTAssertEqual(store.undoableClearSlotID, 1)
            XCTAssertTrue(store.undoLastClear(for: 1))
            XCTAssertEqual(store.slots[1].url, "second-link")
            XCTAssertNil(store.undoableClearSlotID)
        }
    }

    @MainActor
    func testPasteIntoAnotherSlotKeepsUndoAvailable() {
        withStore { store in
            store.slots[0].url = "deleted-link"

            store.clearURL(for: 0)
            store.updateURL(for: 1, to: "other-link")

            XCTAssertEqual(store.undoableClearSlotID, 0)
            XCTAssertTrue(store.undoLastClear(for: 0))
            XCTAssertEqual(store.slots[0].url, "deleted-link")
            XCTAssertEqual(store.slots[1].url, "other-link")
        }
    }

    @MainActor
    func testCancelledOlderExpirationCannotEraseNewerUndo() async throws {
        try await withStore(clearUndoLifetime: .milliseconds(400)) { store in
            store.slots[0].url = "first-link"
            store.slots[1].url = "second-link"

            store.clearURL(for: 0)
            try await Task.sleep(for: .milliseconds(250))
            store.clearURL(for: 1)
            try await Task.sleep(for: .milliseconds(200))

            XCTAssertEqual(store.undoableClearSlotID, 1)
            XCTAssertTrue(store.canUndoLastClear)
            XCTAssertTrue(store.undoLastClear(for: 1))
            XCTAssertEqual(store.slots[1].url, "second-link")
        }
    }

    func testUndoShortcutExcludesRedo() throws {
        XCTAssertTrue(joyIsUndoShortcut(try keyEvent(modifiers: .command)))
        XCTAssertFalse(
            joyIsUndoShortcut(
                try keyEvent(modifiers: [.command, .shift])
            )
        )
    }

    @MainActor
    func testPanelRoutesCommandZDirectlyToClearUndo() throws {
        _ = NSApplication.shared
        let panel = JoyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .nonactivatingPanel,
            backing: .buffered,
            defer: false
        )
        var undoCount = 0
        panel.undoLastClear = {
            undoCount += 1
            return true
        }

        XCTAssertTrue(
            panel.performKeyEquivalent(
                with: try keyEvent(modifiers: .command)
            )
        )
        XCTAssertEqual(undoCount, 1)
    }

    @MainActor
    private func withStore(
        clearUndoLifetime: Duration = .seconds(5),
        body: (MonitorStore) throws -> Void
    ) rethrows {
        let suiteName = "JoyTests.MonitorStoreUndo.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = MonitorStore(
            userDefaults: userDefaults,
            clearUndoLifetime: clearUndoLifetime
        )
        try body(store)
    }

    @MainActor
    private func withStore(
        clearUndoLifetime: Duration,
        body: (MonitorStore) async throws -> Void
    ) async rethrows {
        let suiteName = "JoyTests.MonitorStoreUndo.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = MonitorStore(
            userDefaults: userDefaults,
            clearUndoLifetime: clearUndoLifetime
        )
        try await body(store)
    }

    private func keyEvent(
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "z",
                charactersIgnoringModifiers: "z",
                isARepeat: false,
                keyCode: 6
            )
        )
    }
}

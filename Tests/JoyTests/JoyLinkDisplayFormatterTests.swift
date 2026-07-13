import AppKit
import XCTest
@testable import Joy

final class JoyLinkDisplayFormatterTests: XCTestCase {
    func testChatGPTLinkUsesServiceAndConversationSuffix() {
        let text = "https://chatgpt.com/c/6a55b1c2-9012-43f5-9237-cf773bda4b?model=auto#latest"

        XCTAssertEqual(
            JoyLinkDisplayFormatter.displayText(for: text) { _ in true },
            "ChatGPT · 3bda4b"
        )
    }

    func testChatGPTLabelUsesIdentifierImmediatelyAfterConversationMarker() {
        let text = "https://chatgpt.com/g/g-example/c/ConversationABCDEF/extra"

        XCTAssertEqual(
            JoyLinkDisplayFormatter.displayText(for: text) { _ in true },
            "ChatGPT · ABCDEF"
        )
    }

    func testCodexLinkUsesNormalizedThreadSuffix() {
        let text = "codex://threads/019f5956-db8f-7b82-a0ea-701c8AAC6ABB"

        XCTAssertEqual(
            JoyLinkDisplayFormatter.displayText(for: text) { _ in true },
            "Codex · aac6bb"
        )
    }

    func testShortIdentifierUsesItsFullValue() {
        XCTAssertEqual(
            JoyLinkDisplayFormatter.displayText(
                for: "https://chatgpt.com/c/abc"
            ) { _ in true },
            "ChatGPT · abc"
        )
    }

    func testNarrowSemanticLabelStillPreservesIdentifierSuffix() {
        let text = "https://chatgpt.com/c/6a55b1c2-9012-43f5-9237-cf773bda4b"

        let result = JoyLinkDisplayFormatter.displayText(for: text) {
            $0.count <= 7
        }

        XCTAssertEqual(result, "3bda4b")
    }

    func testReturnsFullTextWhenItFits() {
        let text = "codex://threads/019f5956-db8f-7b82-a0ea"

        let result = JoyLinkDisplayFormatter.displayText(for: text) { _ in true }

        XCTAssertEqual(result, text)
    }

    func testUsesLongestFittingPrefixAndExactSixCharacterSuffix() {
        let text = "abcdefghijklmno"

        let result = JoyLinkDisplayFormatter.displayText(for: text) {
            $0.count <= 11
        }

        XCTAssertEqual(result, "abcd\u{2026}jklmno")
        XCTAssertEqual(String(result.suffix(6)), String(text.suffix(6)))
    }

    func testSuffixNeverOverlapsShortPrefix() {
        let text = "abcdefgh"

        let result = JoyLinkDisplayFormatter.displayText(for: text) {
            $0.count <= 8
        }

        XCTAssertEqual(result, "a\u{2026}cdefgh")
    }

    func testPreservesSixExtendedGraphemeClusters() {
        let text = "prefix-🙂e\u{301}甲乙丙丁戊"

        let result = JoyLinkDisplayFormatter.displayText(for: text) {
            $0.count <= 8
        }

        XCTAssertEqual(String(result.suffix(6)), String(text.suffix(6)))
        XCTAssertEqual(Array(result.suffix(6)).count, 6)
    }

    func testActualFontResultFitsBudget() {
        let fallback = NSFont.systemFont(ofSize: 12, weight: .medium)
        let font = fallback.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 12) }
            ?? fallback
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let budget: CGFloat = 145
        let text = "codex://threads/019f5956-db8f-7b82-a0ea-701c8aac6abb"

        let result = JoyLinkDisplayFormatter.displayText(for: text) {
            ($0 as NSString).size(withAttributes: attributes).width <= budget
        }

        XCTAssertLessThanOrEqual(
            (result as NSString).size(withAttributes: attributes).width,
            budget
        )
        XCTAssertEqual(String(result.suffix(6)), String(text.suffix(6)))
    }
}

final class JoyLinkPasteTests: XCTestCase {
    func testTrimsPastedString() {
        XCTAssertEqual(
            JoyLinkPaste.sanitizedText(
                "  codex://threads/019f5956-db8f-7b82-a0ea  \n"
            ),
            "codex://threads/019f5956-db8f-7b82-a0ea"
        )
    }

    func testRejectsWhitespaceOnlyPaste() {
        XCTAssertNil(JoyLinkPaste.sanitizedText(" \n\t "))
        XCTAssertNil(JoyLinkPaste.sanitizedText(nil))
    }

    func testReadOnlyFieldAcceptsOnlyItsFirstPaste() {
        let field = JoyNativeTextField(frame: .zero)
        var acceptedLinks: [String] = []
        field.onPaste = { acceptedLinks.append($0) }

        field.acceptPastedText("first-link")
        field.acceptPastedText("replacement-link")

        XCTAssertEqual(field.fullText, "first-link")
        XCTAssertEqual(acceptedLinks, ["first-link"])
        XCTAssertFalse(field.acceptsFirstResponder)
        XCTAssertFalse(field.isEditable)
        XCTAssertFalse(field.isSelectable)

        field.fullText = ""

        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.acceptsFirstResponder)

        field.setAccessibilityValue("replacement-link")

        XCTAssertEqual(field.fullText, "")
        XCTAssertEqual(field.stringValue, "")
    }
}

final class JoyLinkContextMenuTests: XCTestCase {
    func testConfiguredFieldOffersCopyAcrossItsFullBounds() throws {
        let field = JoyNativeTextField(
            frame: NSRect(x: 0, y: 0, width: 200, height: 42)
        )
        field.fullText = "https://chatgpt.com/c/conversation"

        let menu = field.menu(for: try rightClickEvent())

        XCTAssertEqual(menu?.items.map(\.title), ["Copy"])
        XCTAssertIdentical(menu?.items.first?.target as AnyObject?, field)
        XCTAssertIdentical(field.hitTest(NSPoint(x: 1, y: 1)), field)
        XCTAssertIdentical(field.hitTest(NSPoint(x: 199, y: 41)), field)
    }

    func testCopyWritesFullLinkInsteadOfShortenedDisplayText() {
        let field = JoyNativeTextField(
            frame: NSRect(x: 0, y: 0, width: 200, height: 42)
        )
        let fullLink = "https://chatgpt.com/c/1234567890-abcdefghijklmnopqrstuvwxyz"
        field.fullText = fullLink
        field.updateDisplayedText()
        XCTAssertEqual(field.stringValue, "ChatGPT · uvwxyz")
        XCTAssertEqual(field.toolTip, fullLink)

        XCTAssertEqual(field.copyableText, fullLink)
    }

    func testEmptyFieldDoesNotOfferCopy() throws {
        let field = JoyNativeTextField(frame: .zero)

        let menu = field.menu(for: try rightClickEvent())

        XCTAssertFalse(menu?.items.contains(where: { $0.title == "Copy" }) ?? false)
    }

    private func rightClickEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            )
        )
    }
}

final class JoyClickDragTrackerTests: XCTestCase {
    func testMouseUpWithoutMeaningfulMovementRemainsAClick() {
        var tracker = JoyClickDragTracker(origin: NSPoint(x: 10, y: 10))

        XCTAssertFalse(tracker.registerDrag(to: NSPoint(x: 12, y: 12)))
        XCTAssertTrue(tracker.registerMouseUp())
        XCTAssertFalse(tracker.registerMouseUp())
    }

    func testCrossingThresholdBeginsOnlyOneDragAndCancelsClick() {
        var tracker = JoyClickDragTracker(origin: .zero)

        XCTAssertTrue(tracker.registerDrag(to: NSPoint(x: 4, y: 0)))
        XCTAssertFalse(tracker.registerDrag(to: NSPoint(x: 20, y: 0)))
        XCTAssertFalse(tracker.registerMouseUp())
    }

    func testAccessibilityPressUsesConfiguredLinkOpenAction() {
        let field = JoyNativeTextField(frame: .zero)
        var openCount = 0
        field.onOpen = { openCount += 1 }

        field.fullText = "https://chatgpt.com/c/conversation"
        XCTAssertTrue(field.accessibilityPerformPress())
        XCTAssertEqual(openCount, 1)

        field.fullText = "unsupported"
        XCTAssertFalse(field.accessibilityPerformPress())
        XCTAssertEqual(openCount, 1)
    }
}

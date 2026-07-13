import AppKit
import XCTest
@testable import Joy

final class JoyLinkDisplayFormatterTests: XCTestCase {
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
            frame: NSRect(x: 0, y: 0, width: 80, height: 42)
        )
        let fullLink = "https://chatgpt.com/c/1234567890-abcdefghijklmnopqrstuvwxyz"
        field.fullText = fullLink
        field.updateDisplayedText()
        XCTAssertNotEqual(field.stringValue, fullLink)

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

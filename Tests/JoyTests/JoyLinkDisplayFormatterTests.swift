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

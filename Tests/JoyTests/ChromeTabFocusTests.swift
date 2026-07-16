import XCTest
@testable import Joy

final class ChromeTabFocusTests: XCTestCase {
    func testMatchingBackgroundWindowIsRaisedAfterChromeActivation() throws {
        let script = ChromeTabFocus.appleScript
        let matchStart = try XCTUnwrap(
            script.range(of: "if currentURL starts with targetURL then")
        ).lowerBound
        let fallbackStart = try XCTUnwrap(
            script.range(of: "if (count of windows) is 0 then")
        ).lowerBound
        let matchingTabBranch = String(script[matchStart..<fallbackStart])

        try assertAppearInOrder(
            [
                "set targetWindowID to id of browserWindow",
                "set minimized of window id targetWindowID to false",
                "set active tab index of window id targetWindowID to tabNumber",
                "activate",
                "if frontmost then exit repeat",
                "set index of window id targetWindowID to 1",
                "return \"found\""
            ],
            in: matchingTabBranch
        )
    }

    private func assertAppearInOrder(
        _ fragments: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var remaining = text[text.startIndex...]

        for fragment in fragments {
            let range = try XCTUnwrap(
                remaining.range(of: fragment),
                "Missing script fragment: \(fragment)",
                file: file,
                line: line
            )
            remaining = remaining[range.upperBound...]
        }
    }
}

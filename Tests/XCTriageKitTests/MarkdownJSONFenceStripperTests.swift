import XCTest
@testable import XCTriageKit

final class MarkdownJSONFenceStripperTests: XCTestCase {

    func test_strip_leavesUnfencedTextUntouched() {
        let text = "{\"a\":1}"
        XCTAssertEqual(MarkdownJSONFenceStripper.strip(text), "{\"a\":1}")
    }

    func test_strip_removesMultiLineFenceWithLanguageTag() {
        let text = "```json\n{\"a\":1}\n```"
        XCTAssertEqual(MarkdownJSONFenceStripper.strip(text), "{\"a\":1}")
    }

    func test_strip_removesMultiLineFenceWithoutLanguageTag() {
        let text = "```\n{\"a\":1}\n```"
        XCTAssertEqual(MarkdownJSONFenceStripper.strip(text), "{\"a\":1}")
    }

    func test_strip_removesSingleLineFenceWithNoEmbeddedNewline() {
        // The risky case: no newline anywhere around the fence markers, so a
        // naive split-on-"\n"-then-drop-first/last strategy empties the
        // whole string instead of stripping just the markers.
        let text = "```{\"a\":1}```"
        XCTAssertEqual(MarkdownJSONFenceStripper.strip(text), "{\"a\":1}")
    }

    func test_strip_handlesMultiLineJSONBodyInsideFence() {
        let text = "```json\n{\n  \"a\": 1,\n  \"b\": 2\n}\n```"
        XCTAssertEqual(MarkdownJSONFenceStripper.strip(text), "{\n  \"a\": 1,\n  \"b\": 2\n}")
    }
}

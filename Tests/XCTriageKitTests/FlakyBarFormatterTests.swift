import XCTest
@testable import XCTriageKit

final class FlakyBarFormatterTests: XCTestCase {

    func test_bar_fullyEmptyAtZero() {
        XCTAssertEqual(FlakyBarFormatter.bar(score: 0, width: 10), String(repeating: "\u{2591}", count: 10))
    }

    func test_bar_fullyFilledAtOne() {
        XCTAssertEqual(FlakyBarFormatter.bar(score: 1, width: 10), String(repeating: "\u{2588}", count: 10))
    }

    func test_bar_halfFilledAtPointFive() {
        let bar = FlakyBarFormatter.bar(score: 0.5, width: 10)
        XCTAssertEqual(bar.filter { $0 == "\u{2588}" }.count, 5)
        XCTAssertEqual(bar.filter { $0 == "\u{2591}" }.count, 5)
    }

    func test_bar_clampsOutOfRangeScores() {
        // scores() and topFlaky() both min(1.0, ...) before this point, but the
        // formatter should not crash or produce a bar of the wrong width if a
        // caller passes something out of [0,1].
        XCTAssertEqual(FlakyBarFormatter.bar(score: 1.5, width: 10).count, 10)
        XCTAssertEqual(FlakyBarFormatter.bar(score: -0.3, width: 10).count, 10)
    }

    func test_scoreLabel_formatsTwoDecimalPlaces() {
        XCTAssertEqual(FlakyBarFormatter.scoreLabel(0.7), "0.70")
        XCTAssertEqual(FlakyBarFormatter.scoreLabel(1.0), "1.00")
    }

    // Regression test: `flaky` used to build its row by interpolating the raw
    // test name into a String(format:) template. A test name containing "%"
    // (parameterized/perf test names do this) would be reinterpreted as a
    // format specifier instead of literal text.
    func test_row_doesNotTreatPercentInNameAsFormatSpecifier() {
        let name = "test_encodesQuery%20string_x100%"
        let row = FlakyBarFormatter.row(name: name, score: 0.42)
        XCTAssertTrue(row.hasSuffix(name), "expected the literal test name to survive unmodified, got: \(row)")
    }

    func test_row_containsScoreAndBar() {
        let row = FlakyBarFormatter.row(name: "SomeTests.test_foo", score: 0.9, width: 10)
        XCTAssertTrue(row.contains("0.90"))
        XCTAssertTrue(row.contains("SomeTests.test_foo"))
    }
}

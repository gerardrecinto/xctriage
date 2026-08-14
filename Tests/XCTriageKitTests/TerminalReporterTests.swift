import XCTest
@testable import XCTriageKit

final class TerminalReporterTests: XCTestCase {

    private func sampleReport(source: CISource, llmUsed: Bool, suggestedFix: String? = "check the expected fixture value") -> TriageReport {
        TriageReport(
            buildID: "build-42",
            source: source,
            classification: ClassificationResult(
                category: .testFailure,
                confidence: 0.75,
                failureSites: [
                    FailureSite(file: "/repo/Tests/FooTests.swift", line: 22, column: nil, testName: "FooTests.test_bar", errorMessage: "XCTAssertEqual failed")
                ],
                summary: "test_bar assertion failed",
                suggestedFix: suggestedFix,
                llmUsed: llmUsed
            ),
            flakyTestScores: ["FooTests.test_bar": 0.6],
            rawLogLines: 80,
            durationMS: 123
        )
    }

    func test_report_includesBuildIDAndSummary() {
        let collector = OutputCollector()
        TerminalReporter(write: collector.write).report(sampleReport(source: .xcodebuild, llmUsed: false))

        let output = collector.joined
        XCTAssertTrue(output.contains("build-42"))
        XCTAssertTrue(output.contains("test_bar assertion failed"))
        XCTAssertTrue(output.contains("rule-based"))
    }

    // Regression test: the analysis-method line used to hardcode
    // "Claude xcodebuild" regardless of the report's actual source.
    func test_report_analysisMethodReflectsActualSource_notHardcodedXcodebuild() {
        let collector = OutputCollector()
        TerminalReporter(write: collector.write).report(sampleReport(source: .githubActions, llmUsed: true))

        let output = collector.joined
        XCTAssertTrue(output.contains("Claude github_actions"), "expected actual source in output, got: \(output)")
        XCTAssertFalse(output.contains("Claude xcodebuild"))
    }

    func test_report_omitsSuggestedFixSectionWhenNil() {
        let collector = OutputCollector()
        TerminalReporter(write: collector.write).report(sampleReport(source: .xcodebuild, llmUsed: false, suggestedFix: nil))

        XCTAssertFalse(collector.joined.contains("SUGGESTED FIX"))
    }
}

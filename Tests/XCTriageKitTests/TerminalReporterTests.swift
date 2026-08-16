import XCTest
@testable import XCTriageKit

final class TerminalReporterTests: XCTestCase {

    private func sampleReport(source: CISource, llmUsed: Bool, suggestedFix: String? = "check the expected fixture value", confidence: Double = 0.75) -> TriageReport {
        TriageReport(
            buildID: "build-42",
            source: source,
            classification: ClassificationResult(
                category: .testFailure,
                confidence: confidence,
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

    // ClassificationResult.confidence is only documented "0.0-1.0" as a
    // comment, never enforced — and ClaudeClassifier parses it straight out
    // of untrusted LLM JSON with no bounds check. confidenceBar builds its
    // bar with `String(repeating:count:)`, which traps on a negative count;
    // an out-of-range confidence (either direction) used to be able to crash
    // this reporter entirely, unlike FlakyBarFormatter right next to it,
    // which already clamps for exactly this reason.
    func test_report_doesNotCrashOnConfidenceAboveOne() {
        let collector = OutputCollector()
        let report = sampleReport(source: .xcodebuild, llmUsed: true, confidence: 1.5)
        TerminalReporter(write: collector.write).report(report)

        XCTAssertTrue(collector.joined.contains("150%"), "confidence display should still show the real value, just with a clamped bar")
    }

    func test_report_doesNotCrashOnNegativeConfidence() {
        let collector = OutputCollector()
        let report = sampleReport(source: .xcodebuild, llmUsed: true, confidence: -0.3)
        TerminalReporter(write: collector.write).report(report)

        XCTAssertTrue(collector.joined.contains("-30%"))
    }
}

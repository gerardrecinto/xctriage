import XCTest
@testable import XCTriageKit

final class GitHubReporterTests: XCTestCase {

    private func site(
        file: String? = "Sources/Foo.swift",
        line: Int? = 10,
        column: Int? = 5,
        testName: String? = nil,
        message: String = "unresolved identifier 'Bar'"
    ) -> FailureSite {
        FailureSite(file: file, line: line, column: column, testName: testName, errorMessage: message)
    }

    private func report(
        category: FailureCategory = .compilationError,
        confidence: Double = 0.91,
        failureSites: [FailureSite]
    ) -> TriageReport {
        TriageReport(
            buildID: "build-42",
            source: .githubActions,
            classification: ClassificationResult(
                category: category,
                confidence: confidence,
                failureSites: failureSites,
                summary: "unresolved identifier 'Bar'",
                suggestedFix: "import the missing module",
                llmUsed: true
            ),
            rawLogLines: 120,
            durationMS: 45.6
        )
    }

    func test_report_emitsErrorAnnotationWithFileLineAndColumn() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(report(failureSites: [site(file: "Sources/Foo.swift", line: 10, column: 5)]))

        XCTAssertEqual(collector.joined, "::error file=Sources/Foo.swift,line=10,col=5::unresolved identifier 'Bar'")
    }

    func test_report_omitsFileLineParamsWhenLocationIsUnknown() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(
            report(failureSites: [site(file: nil, line: nil, column: nil, testName: "FooTests.test_a", message: "flaked out")])
        )

        XCTAssertEqual(collector.joined, "::error::flaked out")
    }

    func test_report_flakyTestCategory_emitsWarning() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(
            report(category: .flakyTest, failureSites: [site(file: nil, line: nil, column: nil, testName: "FooTests.test_a", message: "flaky")])
        )

        XCTAssertEqual(collector.joined, "::warning::flaky")
    }

    func test_report_zeroFailureSites_emitsNoAnnotations() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(report(failureSites: []))

        XCTAssertEqual(collector.joined, "")
    }

    func test_report_multipleFailureSites_emitsOneAnnotationPerSite() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(
            report(failureSites: [
                site(file: "Foo.swift", line: 1, message: "first"),
                site(file: "Bar.swift", line: 2, message: "second"),
            ])
        )

        XCTAssertEqual(collector.joined, "::error file=Foo.swift,line=1,col=5::first\n::error file=Bar.swift,line=2,col=5::second")
    }

    func test_report_escapesNewlinesAndPercentInMessage() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(
            report(failureSites: [site(file: nil, line: nil, column: nil, message: "line one\nline two with 50%")])
        )

        XCTAssertEqual(collector.joined, "::error::line one%0Aline two with 50%25")
    }

    func test_report_lowConfidence_downgradesErrorToWarning() {
        let collector = OutputCollector()
        GitHubReporter(write: collector.write).report(
            report(category: .compilationError, confidence: 0.1, failureSites: [site(file: nil, line: nil, column: nil, message: "boom")])
        )

        XCTAssertEqual(collector.joined, "::warning::boom")
    }
}

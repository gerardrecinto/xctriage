import XCTest
@testable import XCTriageKit

final class JSONReporterTests: XCTestCase {

    private func sampleReport(buildID: String? = "build-42") -> TriageReport {
        TriageReport(
            buildID: buildID,
            source: .githubActions,
            classification: ClassificationResult(
                category: .compilationError,
                confidence: 0.91,
                failureSites: [
                    FailureSite(file: "/repo/Sources/Foo.swift", line: 10, column: 5, testName: nil, errorMessage: "unresolved identifier")
                ],
                summary: "unresolved identifier 'Bar'",
                suggestedFix: "import the missing module",
                llmUsed: true
            ),
            flakyTestScores: ["Suite.test_flaky": 0.8],
            rawLogLines: 120,
            durationMS: 45.6
        )
    }

    func test_report_producesValidJSONWithExpectedFields() throws {
        let collector = OutputCollector()
        try JSONReporter(write: collector.write).report(sampleReport())

        let data = try XCTUnwrap(collector.joined.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["build_id"] as? String, "build-42")
        XCTAssertEqual(obj["source"] as? String, "github_actions")
        XCTAssertEqual(obj["raw_log_lines"] as? Int, 120)

        let classification = try XCTUnwrap(obj["classification"] as? [String: Any])
        XCTAssertEqual(classification["category"] as? String, "compilation_error")
        XCTAssertEqual(classification["llm_used"] as? Bool, true)

        let sites = try XCTUnwrap(classification["failure_sites"] as? [[String: Any]])
        XCTAssertEqual(sites.first?["line"] as? Int, 10)

        let flakyScores = try XCTUnwrap(obj["flaky_test_scores"] as? [String: Double])
        XCTAssertEqual(flakyScores["Suite.test_flaky"], 0.8)
    }

    func test_report_encodesNilBuildIDAsJSONNull() throws {
        let collector = OutputCollector()
        try JSONReporter(write: collector.write).report(sampleReport(buildID: nil))

        let data = try XCTUnwrap(collector.joined.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(obj["build_id"] is NSNull)
    }
}

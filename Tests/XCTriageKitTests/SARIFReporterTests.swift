import XCTest
@testable import XCTriageKit

final class SARIFReporterTests: XCTestCase {

    private func site(
        file: String? = "/repo/Sources/Foo.swift",
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

    private func runResults(_ collector: OutputCollector) throws -> [[String: Any]] {
        let data = try XCTUnwrap(collector.joined.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(obj["runs"] as? [[String: Any]])
        let run = try XCTUnwrap(runs.first)
        return try XCTUnwrap(run["results"] as? [[String: Any]])
    }

    func test_report_producesValidSARIFEnvelope() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(failureSites: [site()]))

        let data = try XCTUnwrap(collector.joined.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["version"] as? String, "2.1.0")
        XCTAssertNotNil(obj["$schema"] as? String)

        let runs = try XCTUnwrap(obj["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)

        let tool = try XCTUnwrap(runs[0]["tool"] as? [String: Any])
        let driver = try XCTUnwrap(tool["driver"] as? [String: Any])
        XCTAssertEqual(driver["name"] as? String, "xctriage")
        XCTAssertNotNil(driver["version"] as? String)
    }

    func test_report_includesLocationWhenFileAndLineArePresent() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(failureSites: [site(file: "/repo/Sources/Foo.swift", line: 10, column: 5)]))

        let results = try runResults(collector)
        XCTAssertEqual(results.count, 1)

        let locations = try XCTUnwrap(results[0]["locations"] as? [[String: Any]])
        let physicalLocation = try XCTUnwrap(locations.first?["physicalLocation"] as? [String: Any])
        let artifactLocation = try XCTUnwrap(physicalLocation["artifactLocation"] as? [String: Any])
        XCTAssertEqual(artifactLocation["uri"] as? String, "/repo/Sources/Foo.swift")

        let region = try XCTUnwrap(physicalLocation["region"] as? [String: Any])
        XCTAssertEqual(region["startLine"] as? Int, 10)
        XCTAssertEqual(region["startColumn"] as? Int, 5)
    }

    func test_report_omitsLocationsWhenNoFileInfoIsAvailable() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(
            report(failureSites: [site(file: nil, line: nil, column: nil, testName: "FooTests.test_a", message: "flaked out")])
        )

        let results = try runResults(collector)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0]["locations"])
    }

    func test_report_zeroFailureSites_producesValidEmptyRun() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(failureSites: []))

        let results = try runResults(collector)
        XCTAssertTrue(results.isEmpty)
    }

    func test_report_includesConfidenceProperty() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(confidence: 0.73, failureSites: [site()]))

        let results = try runResults(collector)
        let properties = try XCTUnwrap(results[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["confidence"] as? Double, 0.73)
    }

    func test_report_multipleFailureSites_identicalContentProducesSameFingerprint() throws {
        let collector = OutputCollector()
        let siteA = site(file: "/repo/Foo.swift", line: 10, message: "boom")
        let siteB = site(file: "/repo/Foo.swift", line: 10, message: "boom")
        try SARIFReporter(write: collector.write).report(report(failureSites: [siteA, siteB]))

        let results = try runResults(collector)
        XCTAssertEqual(results.count, 2)

        let fpA = try XCTUnwrap((results[0]["partialFingerprints"] as? [String: Any])?["xctriageFingerprint/v1"] as? String)
        let fpB = try XCTUnwrap((results[1]["partialFingerprints"] as? [String: Any])?["xctriageFingerprint/v1"] as? String)
        XCTAssertEqual(fpA, fpB)
    }

    func test_report_multipleFailureSites_differentContentProducesDifferentFingerprint() throws {
        let collector = OutputCollector()
        let siteA = site(file: "/repo/Foo.swift", line: 10, message: "boom")
        let siteB = site(file: "/repo/Bar.swift", line: 20, message: "crash")
        try SARIFReporter(write: collector.write).report(report(failureSites: [siteA, siteB]))

        let results = try runResults(collector)
        let fpA = try XCTUnwrap((results[0]["partialFingerprints"] as? [String: Any])?["xctriageFingerprint/v1"] as? String)
        let fpB = try XCTUnwrap((results[1]["partialFingerprints"] as? [String: Any])?["xctriageFingerprint/v1"] as? String)
        XCTAssertNotEqual(fpA, fpB)
    }

    func test_report_ruleIdIsDerivedFromCategory() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(category: .flakyTest, failureSites: [site(testName: "FooTests.test_a")]))

        let results = try runResults(collector)
        XCTAssertEqual(results[0]["ruleId"] as? String, "xctriage/test/flaky")
    }

    func test_report_everyCategoryProducesANonEmptyRuleIdWithoutCrashing() throws {
        for category in FailureCategory.allCases {
            let collector = OutputCollector()
            try SARIFReporter(write: collector.write).report(report(category: category, failureSites: [site()]))
            let results = try runResults(collector)
            let ruleId = try XCTUnwrap(results[0]["ruleId"] as? String)
            XCTAssertFalse(ruleId.isEmpty)
        }
    }

    func test_report_unknownCategory_fallsBackToGenericRuleId() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(category: .unknown, failureSites: [site()]))

        let results = try runResults(collector)
        XCTAssertEqual(results[0]["ruleId"] as? String, "xctriage/unknown")
    }

    func test_report_flakyTestCategory_isWarningLevel() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(category: .flakyTest, failureSites: [site(testName: "FooTests.test_a")]))

        let results = try runResults(collector)
        XCTAssertEqual(results[0]["level"] as? String, "warning")
    }

    func test_report_compilationError_isErrorLevel() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(category: .compilationError, confidence: 0.9, failureSites: [site()]))

        let results = try runResults(collector)
        XCTAssertEqual(results[0]["level"] as? String, "error")
    }

    func test_report_lowConfidence_downgradesErrorToWarning() throws {
        let collector = OutputCollector()
        try SARIFReporter(write: collector.write).report(report(category: .compilationError, confidence: 0.2, failureSites: [site()]))

        let results = try runResults(collector)
        XCTAssertEqual(results[0]["level"] as? String, "warning")
    }
}

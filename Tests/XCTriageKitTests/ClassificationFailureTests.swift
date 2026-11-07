import XCTest
@testable import XCTriageKit

final class ClassificationFailureTests: XCTestCase {
    func testDependencyFailureWithoutLocationStillFailsGate() {
        let parser = BuildLogParser()
        let entries = parser.extractFailureContext(parser.parse("error: Swift package resolution failed"))
        let result = RuleClassifier().classify(entries)
        XCTAssertEqual(result.category, .dependencyFailure)
        XCTAssertTrue(parser.extractFailureSites(entries).isEmpty)
        XCTAssertTrue(result.hasDetectedFailure)
    }

    func testKnownFailureCategoriesDoNotRequireSites() {
        for category in FailureCategory.allCases where category != .unknown {
            let result = ClassificationResult(category: category, confidence: 0.8, summary: "classified")
            XCTAssertTrue(result.hasDetectedFailure, category.rawValue)
        }
    }

    func testUnknownWithFailureSiteStillFailsGate() {
        let site = FailureSite(file: nil, line: nil, column: nil, testName: nil, errorMessage: "failed")
        let result = ClassificationResult(category: .unknown, confidence: 0, failureSites: [site], summary: "unknown")
        XCTAssertTrue(result.hasDetectedFailure)
    }

    func testUnknownWithoutEvidenceDoesNotFailGate() {
        let parser = BuildLogParser()
        let result = RuleClassifier().classify(parser.extractFailureContext(parser.parse("** BUILD SUCCEEDED **")))
        XCTAssertEqual(result.category, .unknown)
        XCTAssertTrue(result.failureSites.isEmpty)
        XCTAssertFalse(result.hasDetectedFailure)
    }
}

import XCTest
@testable import XCTriageKit

final class XCResultCategoryFallbackTests: XCTestCase {

    private func site(testName: String?) -> FailureSite {
        FailureSite(file: nil, line: nil, column: nil, testName: testName, errorMessage: "failed - some message")
    }

    func test_apply_overridesUnknownWhenAFailureSiteHasATestName() {
        // A bare XCTFail("message") call — verified empirically against a
        // real xcresult bundle — produces "failed - message" with no
        // "XCTAssert" prefix, matching zero RuleClassifier rules. But its
        // FailureSite carries a non-nil testName, a structural signal (from
        // xcresulttool's testFailureSummaries, which never appears for
        // build errors) that RuleClassifier's text patterns never see.
        let ruleResult = ClassificationResult(category: .unknown, confidence: 0.0, summary: "No matching failure pattern found")
        let result = XCResultCategoryFallback.apply(ruleResult: ruleResult, failureSites: [site(testName: "Foo.test_a")])

        XCTAssertEqual(result.category, .testFailure)
        XCTAssertEqual(result.confidence, 0.95)
    }

    func test_apply_leavesAnAlreadyClassifiedResultAlone() {
        let ruleResult = ClassificationResult(category: .compilationError, confidence: 0.9, summary: "already classified")
        let result = XCResultCategoryFallback.apply(ruleResult: ruleResult, failureSites: [site(testName: "Foo.test_a")])

        XCTAssertEqual(result.category, .compilationError)
        XCTAssertEqual(result.confidence, 0.9)
        XCTAssertEqual(result.summary, "already classified")
    }

    func test_apply_leavesUnknownAloneWhenNoFailureSiteHasATestName() {
        // No testName anywhere means every site came from errorSummaries
        // (generic build issues), not testFailureSummaries — no structural
        // signal to trust, so there's nothing to override with.
        let ruleResult = ClassificationResult(category: .unknown, confidence: 0.0, summary: "No matching failure pattern found")
        let result = XCResultCategoryFallback.apply(ruleResult: ruleResult, failureSites: [site(testName: nil)])

        XCTAssertEqual(result.category, .unknown)
    }

    func test_apply_leavesUnknownAloneWhenNoFailureSitesAtAll() {
        let ruleResult = ClassificationResult(category: .unknown, confidence: 0.0, summary: "No matching failure pattern found")
        let result = XCResultCategoryFallback.apply(ruleResult: ruleResult, failureSites: [])

        XCTAssertEqual(result.category, .unknown)
    }

    func test_apply_preservesFailureSitesFromTheOriginalResult() {
        let sites = [site(testName: "Foo.test_a")]
        let ruleResult = ClassificationResult(category: .unknown, confidence: 0.0, failureSites: sites, summary: "No matching failure pattern found")
        let result = XCResultCategoryFallback.apply(ruleResult: ruleResult, failureSites: sites)

        XCTAssertEqual(result.failureSites, sites)
    }
}

// RuleClassifier only sees synthetic message text built from a FailureSite's
// locationDescription + errorMessage — it has no idea whether that site came
// from xcresulttool's testFailureSummaries (a genuine XCTest failure) or
// errorSummaries (a generic build issue). A bare `XCTFail("message")` call
// produces "failed - message" with no "XCTAssert" prefix (verified against a
// real xcresult bundle from `xcodebuild test`), so it matches zero
// RuleClassifier rules and comes back .unknown even though the failure is
// definitely a test failure. FailureSite.testName is only ever non-nil for a
// testFailureSummaries entry (never errorSummaries) — a structural signal
// RuleClassifier's text patterns can't see but this type can act on.
public enum XCResultCategoryFallback {
    public static func apply(ruleResult: ClassificationResult, failureSites: [FailureSite]) -> ClassificationResult {
        guard ruleResult.category == .unknown,
              failureSites.contains(where: { $0.testName != nil }) else {
            return ruleResult
        }
        var result = ruleResult
        result.category = .testFailure
        result.confidence = 0.95
        result.summary = "XCTest failure (xcresult test failure summary; message text matched no rule pattern)"
        result.suggestedFix = "Run the failing test in Xcode with the same scheme. Check XCResult bundle in DerivedData for stack trace and attachment."
        return result
    }
}

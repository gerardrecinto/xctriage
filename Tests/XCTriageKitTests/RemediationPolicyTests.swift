import XCTest
@testable import XCTriageKit

final class RemediationPolicyTests: XCTestCase {

    func test_isEligibleForRemediation_allowsFlakyTestAboveThreshold() {
        let policy = RemediationPolicy()
        let decision = policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.75, attemptNumber: 1)
        XCTAssertEqual(decision, .allowed)
    }

    func test_isEligibleForRemediation_allowsCompilationErrorAboveThreshold() {
        let policy = RemediationPolicy()
        let decision = policy.isEligibleForRemediation(category: .compilationError, confidence: 0.90, attemptNumber: 1)
        XCTAssertEqual(decision, .allowed)
    }

    func test_isEligibleForRemediation_deniesDisallowedCategory() {
        let policy = RemediationPolicy()
        let decision = policy.isEligibleForRemediation(category: .timeout, confidence: 0.99, attemptNumber: 1)
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isEligibleForRemediation_deniesBelowConfidenceThreshold() {
        let policy = RemediationPolicy()
        let decision = policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.40, attemptNumber: 1)
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isEligibleForRemediation_deniesWhenAttemptExceedsMax() {
        let policy = RemediationPolicy()
        let decision = policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.90, attemptNumber: 2)
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isPatchAllowed_allowsSingleFileOutsideForbiddenPaths() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["Sources/XCTriageKit/Parsers/BuildLogParser.swift"])
        XCTAssertEqual(decision, .allowed)
    }

    func test_isPatchAllowed_deniesWhenMoreThanMaxFilesChanged() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: [
            "Sources/XCTriageKit/Parsers/BuildLogParser.swift",
            "Sources/XCTriageKit/Parsers/XCResultParser.swift",
        ])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isPatchAllowed_deniesEmptyFileList() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: [])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isPatchAllowed_deniesForbiddenClassifierPath() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["Sources/XCTriageKit/Classifiers/RuleClassifier.swift"])
        guard case .denied(let reason) = decision else { return XCTFail("expected denied") }
        XCTAssertTrue(reason.contains("forbidden"))
    }

    func test_isPatchAllowed_deniesForbiddenWorkflowPath() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: [".github/workflows/ci.yml"])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isPatchAllowed_deniesPackageManifest() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["Package.swift"])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_customPolicy_respectsOverriddenThresholds() {
        let policy = RemediationPolicy(minConfidence: 0.95, maxFilesChanged: 3, maxAttempts: 2)
        XCTAssertEqual(policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.90, attemptNumber: 1), .denied(reason: "confidence 0.9 below minimum 0.95"))
        XCTAssertEqual(policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.96, attemptNumber: 2), .allowed)
    }
}

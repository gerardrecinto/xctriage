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

    // PatchProposal.filePath comes straight from the LLM's own JSON ("echo
    // back the path you were given"), so its casing isn't guaranteed to
    // exactly match the on-disk path. macOS's default filesystem (APFS) is
    // case-insensitive-but-preserving, so "sources/xctriage/main.swift" and
    // "Sources/xctriage/main.swift" are the SAME file on disk, but
    // String.hasPrefix is case-sensitive — a differently-cased path used to
    // sail past this safety-rail check entirely.
    func test_isPatchAllowed_deniesForbiddenPathRegardlessOfCase() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["sources/xctriage/main.swift"])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_isPatchAllowed_deniesPackageManifestRegardlessOfCase() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["package.swift"])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    // The Classifiers/ and Policy/ directories were already forbidden, but the
    // remediation pipeline itself (PatchGenerator, SandboxValidator,
    // GitHubPRWriter, RemediationStateMachine, IdempotencyStore) was not —
    // meaning a compilation_error in one of those files could have produced
    // a PR that patches the tool's own safety machinery. Same "can't rewrite
    // its own safety rails" instinct as the existing forbidden paths.
    func test_isPatchAllowed_deniesRemediationPipelinePath() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["Sources/XCTriageKit/Remediation/SandboxValidator.swift"])
        guard case .denied(let reason) = decision else { return XCTFail("expected denied") }
        XCTAssertTrue(reason.contains("forbidden"))
    }

    // The CLI entrypoint wires the policy gate, the state machine, and the
    // idempotency store together — a self-patch there could alter how those
    // gates are invoked without ever touching a "forbidden" file by name.
    func test_isPatchAllowed_deniesCLIEntrypointPath() {
        let policy = RemediationPolicy()
        let decision = policy.isPatchAllowed(filesChanged: ["Sources/xctriage/main.swift"])
        guard case .denied = decision else { return XCTFail("expected denied, got \(decision)") }
    }

    func test_customPolicy_respectsOverriddenThresholds() {
        let policy = RemediationPolicy(minConfidence: 0.95, maxFilesChanged: 3, maxAttempts: 2)
        XCTAssertEqual(policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.90, attemptNumber: 1), .denied(reason: "confidence 0.9 below minimum 0.95"))
        XCTAssertEqual(policy.isEligibleForRemediation(category: .flakyTest, confidence: 0.96, attemptNumber: 2), .allowed)
    }
}

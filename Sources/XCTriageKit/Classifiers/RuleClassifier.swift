import Foundation
import RegexBuilder

public struct ClassifierRule: Sendable {
    public let pattern: String
    public let category: FailureCategory
    public let weight: Double
    public let summaryTemplate: String
    public let fixTemplate: String?

    public init(
        pattern: String,
        category: FailureCategory,
        weight: Double,
        summaryTemplate: String,
        fixTemplate: String? = nil
    ) {
        self.pattern = pattern
        self.category = category
        self.weight = weight
        self.summaryTemplate = summaryTemplate
        self.fixTemplate = fixTemplate
    }
}

// Default rules covering Apple CI failure modes and generic CI patterns
internal let defaultRules: [ClassifierRule] = [
    // Compilation: Swift/ObjC
    ClassifierRule(
        pattern: #"(?i)(cannot find|unresolved identifier|type .* has no member|undeclared identifier|use of unresolved identifier)"#,
        category: .compilationError, weight: 0.92,
        summaryTemplate: "Swift/ObjC unresolved symbol or type error",
        fixTemplate: "Check import statements and module visibility. Run `xcodebuild -showBuildSettings` to verify framework search paths."
    ),
    ClassifierRule(
        pattern: #"(?i)(value of type .* has no member|cannot convert value of type)"#,
        category: .compilationError, weight: 0.91,
        summaryTemplate: "Swift type mismatch or missing member",
        fixTemplate: "Verify the API exists for the target SDK version. Check for a deprecated API that changed signature."
    ),
    ClassifierRule(
        pattern: #"(?i)(linker command failed|ld: .*not found|framework not found|library not found|symbol.* not found)"#,
        category: .compilationError, weight: 0.90,
        summaryTemplate: "Linker error: missing framework or symbol",
        fixTemplate: "Verify FRAMEWORK_SEARCH_PATHS and check that all linked frameworks are present in DerivedData."
    ),
    ClassifierRule(
        pattern: #"(?i)codesign.*(failed|error)"#,
        category: .compilationError, weight: 0.87,
        summaryTemplate: "Code signing failed",
        fixTemplate: "Check provisioning profile, certificate validity, and team ID. Run `security find-identity -v` to list valid certificates."
    ),
    // Test failures
    ClassifierRule(
        pattern: #"Test Case '.+?' failed \([0-9.]+ seconds\)"#,
        category: .testFailure, weight: 0.95,
        summaryTemplate: "XCTest case failed",
        fixTemplate: "Run the failing test in Xcode with the same scheme. Check XCResult bundle in DerivedData for stack trace and attachment."
    ),
    ClassifierRule(
        pattern: #"(?i)XCTAssert.*(failed|assertion)"#,
        category: .testFailure, weight: 0.88,
        summaryTemplate: "XCTAssert assertion failed",
        fixTemplate: "Check the assertion parameters. Add `continueAfterFailure = false` to stop on first failure for faster root-cause isolation."
    ),
    ClassifierRule(
        pattern: #"(?i)\*\* TEST FAILED \*\*"#,
        category: .testFailure, weight: 0.90,
        summaryTemplate: "Test suite reported failures",
        fixTemplate: "Check individual test case output above. Use `xcresulttool get --format json` to extract structured failure data."
    ),
    // Flaky / intermittent
    ClassifierRule(
        pattern: #"(?i)(flaky|intermittent|timeout.*retry|connection refused.*test|async.*did not complete)"#,
        category: .flakyTest, weight: 0.75,
        summaryTemplate: "Potential flaky test: intermittent or async-timing signal",
        fixTemplate: "Add explicit `XCTNSNotificationExpectation` or `XCTKVOExpectation`. Avoid `Thread.sleep`: use `wait(for:timeout:)` instead."
    ),
    // Resource exhaustion
    ClassifierRule(
        pattern: #"(?i)(out of memory|OOMKilled|memory pressure|killed: 9|signal 9|Killed\b)"#,
        category: .resourceExhaustion, weight: 0.93,
        summaryTemplate: "OOM: build agent killed by memory pressure",
        fixTemplate: "Reduce -jobs count for xcodebuild. Add `OTHER_SWIFT_FLAGS = -Onone` for debug builds to lower peak compiler memory."
    ),
    ClassifierRule(
        pattern: #"(?i)(no space left|disk space|disk full)"#,
        category: .resourceExhaustion, weight: 0.95,
        summaryTemplate: "Disk exhaustion on CI agent",
        fixTemplate: "Clean DerivedData between builds: `rm -rf ~/Library/Developer/Xcode/DerivedData`. Add a pre-build disk-check step."
    ),
    // Infra failures
    ClassifierRule(
        pattern: #"(?i)(git clone|git fetch|git lfs|smudge).*(failed|error|timeout|403|401)"#,
        category: .infraFailure, weight: 0.90,
        summaryTemplate: "Git or LFS fetch failure",
        fixTemplate: "Check SCM credentials and proxy settings on the CI agent. Verify LFS endpoint availability."
    ),
    ClassifierRule(
        pattern: #"(?i)(xcode-select|xcrun).*(error|not found|no such)"#,
        category: .infraFailure, weight: 0.88,
        summaryTemplate: "xcode-select or xcrun failure: Xcode not installed or wrong path",
        fixTemplate: "Run `sudo xcode-select --switch /Applications/Xcode.app`. Verify Xcode version matches the one used to generate the xcresult."
    ),
    ClassifierRule(
        pattern: #"(?i)(simulator|boot|simctl).*(failed|error|timeout)"#,
        category: .infraFailure, weight: 0.83,
        summaryTemplate: "iOS Simulator boot or simctl failure",
        fixTemplate: "Run `xcrun simctl shutdown all && xcrun simctl erase all`. Ensure the requested device type exists with `xcrun simctl list`."
    ),
    // Dependencies
    ClassifierRule(
        pattern: #"(?i)(swift package|spm|package.*resolved).*(failed|error|missing)"#,
        category: .dependencyFailure, weight: 0.87,
        summaryTemplate: "Swift Package Manager dependency resolution failed",
        fixTemplate: "Delete Package.resolved and re-run `swift package resolve`. Check network access to package registry from CI agent."
    ),
    ClassifierRule(
        pattern: #"(?i)(cocoapods|pod install|podfile).*(failed|error)"#,
        category: .dependencyFailure, weight: 0.85,
        summaryTemplate: "CocoaPods installation failed",
        fixTemplate: "Run `pod repo update` then `pod install`. Check CDN pod spec connectivity from CI agent."
    ),
    // Timeout
    ClassifierRule(
        pattern: #"(?i)(build.*timed? ?out|timeout.*exceeded|deadline exceeded|signal: killed|Timed out)"#,
        category: .timeout, weight: 0.90,
        summaryTemplate: "Build or test timed out",
        fixTemplate: "Increase timeout with `xcodebuild -timeout` flag. Split large test suites across parallel destinations with `-parallel-testing-enabled YES`."
    ),
]

public struct RuleClassifier: Sendable {

    private let rules: [ClassifierRule]
    private let compiledRules: [(NSRegularExpression, ClassifierRule)]

    public init(rules: [ClassifierRule]? = nil) {
        let resolvedRules = rules ?? defaultRules
        self.rules = resolvedRules
        self.compiledRules = resolvedRules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else { return nil }
            return (regex, rule)
        }
    }

    public func classify(_ entries: [LogEntry]) -> ClassificationResult {
        let combined = entries.map(\.message).joined(separator: "\n")
        let range = NSRange(combined.startIndex..., in: combined)

        // Track a single winning rule directly rather than a per-category
        // score dictionary: a previous version picked the reported category
        // from Dictionary.max(by:) separately from the rule used for the
        // summary/fix text, and Dictionary iteration order isn't guaranteed
        // to agree with this loop's array order. On a weight tie between two
        // different categories, that let the reported category and the
        // reported summary come from two different rules — verified
        // empirically: category flipped between process runs while summary
        // stayed fixed. Keeping one winning rule for everything closes that.
        var bestRule: ClassifierRule?
        for (regex, rule) in compiledRules where regex.firstMatch(in: combined, range: range) != nil {
            if bestRule == nil || rule.weight > (bestRule?.weight ?? 0) {
                bestRule = rule
            }
        }

        guard let topRule = bestRule else {
            return ClassificationResult(
                category: .unknown,
                confidence: 0.0,
                summary: "No matching failure pattern found",
                suggestedFix: "Enable verbose logging (-verbose flag) and re-run to capture more context."
            )
        }

        return ClassificationResult(
            category: topRule.category,
            confidence: topRule.weight,
            summary: topRule.summaryTemplate,
            suggestedFix: topRule.fixTemplate,
            llmUsed: false
        )
    }
}

import Foundation

// Deterministic autonomy gate for AI-generated remediation. No LLM call
// happens here: confidence/category/attempt data comes from upstream
// classification, but the decision to proceed is a plain rule evaluation.
public struct RemediationPolicy: Sendable {

    public enum Decision: Equatable, Sendable {
        case allowed
        case denied(reason: String)
    }

    public let allowedCategories: Set<FailureCategory>
    public let minConfidence: Double
    public let maxFilesChanged: Int
    public let maxAttempts: Int
    public let forbiddenPathPrefixes: [String]

    public init(
        allowedCategories: Set<FailureCategory> = [.flakyTest, .compilationError],
        minConfidence: Double = 0.60,
        maxFilesChanged: Int = 1,
        maxAttempts: Int = 1,
        forbiddenPathPrefixes: [String] = [
            "Sources/XCTriageKit/Classifiers/",
            "Sources/XCTriageKit/Policy/",
            "Sources/XCTriageKit/Remediation/",
            "Sources/xctriage/",
            ".github/",
            "Package.swift",
            "Jenkinsfile",
        ]
    ) {
        self.allowedCategories = allowedCategories
        self.minConfidence = minConfidence
        self.maxFilesChanged = maxFilesChanged
        self.maxAttempts = maxAttempts
        self.forbiddenPathPrefixes = forbiddenPathPrefixes
    }

    // Pre-generation gate: is this failure class even eligible for an attempt?
    public func isEligibleForRemediation(category: FailureCategory, confidence: Double, attemptNumber: Int) -> Decision {
        guard allowedCategories.contains(category) else {
            return .denied(reason: "category \(category.rawValue) is not in the auto-remediation allowlist")
        }
        guard confidence >= minConfidence else {
            return .denied(reason: "confidence \(confidence) below minimum \(minConfidence)")
        }
        guard attemptNumber <= maxAttempts else {
            return .denied(reason: "attempt \(attemptNumber) exceeds max attempts \(maxAttempts)")
        }
        return .allowed
    }

    // Post-generation gate: is the actual diff's file set allowed to become a PR?
    public func isPatchAllowed(filesChanged: [String]) -> Decision {
        guard !filesChanged.isEmpty else {
            return .denied(reason: "patch changes no files")
        }
        guard filesChanged.count <= maxFilesChanged else {
            return .denied(reason: "patch changes \(filesChanged.count) files, exceeds max \(maxFilesChanged)")
        }
        for path in filesChanged {
            if let forbidden = forbiddenPathPrefixes.first(where: { path.hasPrefix($0) || path == $0 }) {
                return .denied(reason: "path \(path) is forbidden (\(forbidden))")
            }
        }
        return .allowed
    }
}

import Foundation

public struct ClassificationResult: Sendable {
    public var category: FailureCategory
    public var confidence: Double   // 0.0–1.0
    public var failureSites: [FailureSite]
    public var summary: String
    public var suggestedFix: String?
    public var llmUsed: Bool

    public init(
        category: FailureCategory,
        confidence: Double,
        failureSites: [FailureSite] = [],
        summary: String,
        suggestedFix: String? = nil,
        llmUsed: Bool = false
    ) {
        self.category = category
        self.confidence = confidence
        self.failureSites = failureSites
        self.summary = summary
        self.suggestedFix = suggestedFix
        self.llmUsed = llmUsed
    }
}

public struct TriageReport: Sendable {
    public let buildID: String?
    public let source: CISource
    public let timestamp: Date
    public let classification: ClassificationResult
    public let flakyTestScores: [String: Double]
    public let rawLogLines: Int
    public let durationMS: Double

    public init(
        buildID: String?,
        source: CISource,
        timestamp: Date = Date(),
        classification: ClassificationResult,
        flakyTestScores: [String: Double] = [:],
        rawLogLines: Int,
        durationMS: Double
    ) {
        self.buildID = buildID
        self.source = source
        self.timestamp = timestamp
        self.classification = classification
        self.flakyTestScores = flakyTestScores
        self.rawLogLines = rawLogLines
        self.durationMS = durationMS
    }
}

public enum CISource: String, Sendable, Codable {
    case xcodebuild    = "xcodebuild"
    case xcresult      = "xcresult"
    case githubActions = "github_actions"
    case generic       = "generic"
}

public enum TriageError: Error, Sendable {
    case fileNotFound(String)
    case xcresultToolFailed(Int32, String)
    case parseError(String)
    case claudeAPIError(Int, String)
    case slackWebhookFailed(Int, String)
    case missingAPIKey
}

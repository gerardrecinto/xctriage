import Foundation

public struct ClassificationResult: Sendable {
    public var category: FailureCategory
    public var confidence: Double   // 0.0-1.0
    public var failureSites: [FailureSite]
    public var summary: String
    public var suggestedFix: String?
    public var llmUsed: Bool

    /// A classified failure does not need a source location to fail a CI gate.
    public var hasDetectedFailure: Bool {
        category != .unknown || !failureSites.isEmpty
    }

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
    case notAFile(String)
    case unreadable(String)
    case xcresultToolFailed(Int32, String)
    case parseError(String)
    case claudeAPIError(Int, String)
    case slackWebhookFailed(Int, String)
    case missingAPIKey
    case remediationCommandFailed(String, String)
    case sandboxTimedOut(command: String, seconds: TimeInterval)
}

extension TriageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .notAFile(let path):
            return "\(path) is a directory. Pass the path of a log file."
        case .unreadable(let path):
            return "Could not read \(path). Check that you have permission to open it."
        case .xcresultToolFailed(let code, let detail):
            return "xcresulttool exited with status \(code): \(detail)"
        case .parseError(let detail):
            return detail
        case .claudeAPIError(let status, let detail):
            return "Claude API returned status \(status): \(detail)"
        case .slackWebhookFailed(let status, let detail):
            return "Slack webhook returned status \(status): \(detail)"
        case .missingAPIKey:
            return "No API key. Set XCTRIAGE_ANTHROPIC_API_KEY to use --llm."
        case .remediationCommandFailed(let command, let detail):
            return "Command failed: \(command): \(detail)"
        case .sandboxTimedOut(let command, let seconds):
            return "Command timed out after \(Int(seconds)) seconds: \(command)"
        }
    }
}

/// Reads a build log from disk. Bytes that are not valid UTF-8 become replacement
/// characters, so one bad byte does not stop the log from being analyzed.
public enum LogFile {
    public static func read(_ path: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw TriageError.fileNotFound(path)
        }
        if isDirectory.boolValue { throw TriageError.notAFile(path) }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw TriageError.unreadable(path)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

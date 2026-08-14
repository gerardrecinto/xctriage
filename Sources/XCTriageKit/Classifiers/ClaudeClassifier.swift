import Foundation

// Claude API failure classifier. Uses URLSession: no external SDK.
// System prompt is sent with ephemeral cache control for cost efficiency on repeated calls.
public actor ClaudeClassifier {

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxLogChars = 4_000

    private static let systemPrompt = """
    You are a CI/CD failure triage expert for Apple platforms (xcodebuild, XCTest, Swift, ObjC).
    Given a CI build log excerpt, respond with JSON only: no prose:
    {
      "category": "<compilation_error|test_failure|flaky_test|resource_exhaustion|infra_failure|dependency_failure|timeout|unknown>",
      "confidence": <float 0.0-1.0>,
      "summary": "<one sentence root cause>",
      "suggested_fix": "<one actionable fix>",
      "failure_sites": [
        {"file": "<path or null>", "line": <int or null>, "test_name": "<str or null>", "error_message": "<str>"}
      ]
    }
    """

    public init(
        apiKey: String,
        model: String = "claude-sonnet-5",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func classify(_ entries: [LogEntry]) async throws -> ClassificationResult {
        let logText = truncated(entries)
        let requestBody = try buildRequest(logText: logText)
        let responseData = try await post(requestBody)
        return try parse(responseData)
    }

    // MARK: - Private

    private func truncated(_ entries: [LogEntry]) -> String {
        let text = entries.map(\.message).joined(separator: "\n")
        guard text.count > Self.maxLogChars else { return text }
        let half = Self.maxLogChars / 2
        let start = text.prefix(half)
        let end = text.suffix(half)
        return "\(start)\n...[truncated]...\n\(end)"
    }

    private func buildRequest(logText: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": [
                [
                    "type": "text",
                    "text": Self.systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ]
            ],
            "messages": [
                ["role": "user", "content": logText]
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw TriageError.parseError("Failed to encode Claude API request body")
        }
        return data
    }

    private func post(_ body: Data) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TriageError.claudeAPIError(0, "Invalid response type")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw TriageError.claudeAPIError(http.statusCode, msg)
        }
        return data
    }

    private func parse(_ data: Data) throws -> ClassificationResult {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (outer["content"] as? [[String: Any]])?.first,
              let rawText = content["text"] as? String else {
            throw TriageError.parseError("Unexpected Claude response shape")
        }

        // Strip optional markdown code fence
        var json = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: "\n")
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        }

        guard let jsonData = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TriageError.parseError("Could not parse Claude JSON response")
        }

        let categoryStr = obj["category"] as? String ?? "unknown"
        let category = FailureCategory(rawValue: categoryStr) ?? .unknown
        let confidence = obj["confidence"] as? Double ?? 0.5
        let summary = obj["summary"] as? String ?? "LLM triage complete"
        let fix = obj["suggested_fix"] as? String

        let rawSites = obj["failure_sites"] as? [[String: Any]] ?? []
        let sites = rawSites.map { s -> FailureSite in
            FailureSite(
                file: s["file"] as? String,
                line: s["line"] as? Int,
                column: nil,
                testName: s["test_name"] as? String,
                errorMessage: s["error_message"] as? String ?? ""
            )
        }

        return ClassificationResult(
            category: category,
            confidence: confidence,
            failureSites: sites,
            summary: summary,
            suggestedFix: fix,
            llmUsed: true
        )
    }
}

import Foundation

// Claude-backed minimal-diff proposal generator. Mirrors ClaudeClassifier's
// URLSession/actor shape deliberately: same request/response plumbing,
// different system prompt and output schema. The model proposes a diff;
// it never applies one — SandboxValidator and RemediationPolicy decide that.
public actor PatchGenerator {

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxFileChars = 6_000

    private static let systemPrompt = """
    You are a minimal-diff remediation engineer for Apple platform CI failures (xcodebuild, XCTest, Swift, ObjC).
    You will be given one failing file's contents and the failure evidence for it.
    Propose the smallest possible fix to that single file only. Respond with JSON only: no prose:
    {
      "file_path": "<path to the file you were given>",
      "unified_diff": "<unified diff patching only that file>",
      "rationale": "<one sentence explaining why this fixes the observed failure>",
      "confidence": <float 0.0-1.0>
    }
    If you cannot propose a safe minimal fix, set confidence to 0.0 and explain why in rationale.
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

    public func proposePatch(
        category: FailureCategory,
        failureSite: FailureSite,
        fileContents: String
    ) async throws -> PatchProposal {
        let userContent = buildUserContent(category: category, failureSite: failureSite, fileContents: fileContents)
        let requestBody = try buildRequest(userContent: userContent)
        let responseData = try await post(requestBody)
        return try parse(responseData)
    }

    // MARK: - Private

    private func buildUserContent(category: FailureCategory, failureSite: FailureSite, fileContents: String) -> String {
        let truncated = fileContents.count > Self.maxFileChars
            ? String(fileContents.prefix(Self.maxFileChars)) + "\n...[truncated]..."
            : fileContents

        return """
        Category: \(category.rawValue)
        File: \(failureSite.file ?? "unknown")
        Test: \(failureSite.testName ?? "unknown")
        Error: \(failureSite.errorMessage)

        File contents:
        \(truncated)
        """
    }

    private func buildRequest(userContent: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": [
                [
                    "type": "text",
                    "text": Self.systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ]
            ],
            "messages": [
                ["role": "user", "content": userContent]
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

    private func parse(_ data: Data) throws -> PatchProposal {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (outer["content"] as? [[String: Any]])?.first,
              let rawText = content["text"] as? String else {
            throw TriageError.parseError("Unexpected Claude response shape")
        }

        var json = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            // Multi-line fence (```json\n{...}\n```): drop the opening fence
            // line (with or without a language tag) up to its newline.
            // Single-line fence (```{...}```, no embedded newline around the
            // markers): fall back to just stripping the leading marker.
            if let firstNewline = json.firstIndex(of: "\n") {
                json = String(json[json.index(after: firstNewline)...])
            } else {
                json.removeFirst(3)
            }
            if json.hasSuffix("```") {
                json.removeLast(3)
            }
            json = json.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jsonData = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TriageError.parseError("Could not parse Claude JSON response")
        }

        guard let filePath = obj["file_path"] as? String,
              let unifiedDiff = obj["unified_diff"] as? String else {
            throw TriageError.parseError("Claude response missing required patch fields")
        }
        let rationale = obj["rationale"] as? String ?? ""
        let confidence = obj["confidence"] as? Double ?? 0.0

        return PatchProposal(filePath: filePath, unifiedDiff: unifiedDiff, rationale: rationale, confidence: confidence)
    }
}

import Foundation

public struct SlackReporter: Sendable {

    private let webhookURL: URL
    private let session: URLSession

    private static let categoryEmoji: [FailureCategory: String] = [
        .compilationError:   ":red_circle:",
        .testFailure:        ":x:",
        .flakyTest:          ":large_yellow_circle:",
        .resourceExhaustion: ":exclamation:",
        .infraFailure:       ":rotating_light:",
        .dependencyFailure:  ":warning:",
        .timeout:            ":hourglass:",
        .unknown:            ":grey_question:",
    ]

    public init(webhookURL: URL, session: URLSession = .shared) {
        self.webhookURL = webhookURL
        self.session = session
    }

    public func report(_ triage: TriageReport) async throws {
        let c = triage.classification
        let emoji = Self.categoryEmoji[c.category] ?? ":grey_question:"

        var blocks: [[String: Any]] = [
            [
                "type": "header",
                "text": ["type": "plain_text", "text": "\(emoji) xctriage: \(c.category.displayName)"],
            ],
            [
                "type": "section",
                "fields": [
                    ["type": "mrkdwn", "text": "*Build:*\n\(triage.buildID ?? "unknown")"],
                    ["type": "mrkdwn", "text": "*Source:*\n\(triage.source.rawValue)"],
                    ["type": "mrkdwn", "text": "*Confidence:*\n\(Int(c.confidence * 100))%"],
                    ["type": "mrkdwn", "text": "*Log lines:*\n\(triage.rawLogLines)"],
                ],
            ],
            [
                "type": "section",
                "text": ["type": "mrkdwn", "text": "*Root cause:*\n\(c.summary)"],
            ],
        ]

        if let fix = c.suggestedFix {
            blocks.append([
                "type": "section",
                "text": ["type": "mrkdwn", "text": "*Suggested fix:*\n\(fix)"],
            ])
        }

        if !c.failureSites.isEmpty {
            let sitesText = c.failureSites.prefix(5).map { s in
                "• `\(s.locationDescription)`: \(s.errorMessage)"
            }.joined(separator: "\n")
            blocks.append([
                "type": "section",
                "text": ["type": "mrkdwn", "text": "*Failure sites:*\n\(sitesText)"],
            ])
        }

        let payload = try JSONSerialization.data(withJSONObject: ["blocks": blocks])
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TriageError.slackWebhookFailed(status, "Slack webhook returned non-200 status")
        }
    }
}

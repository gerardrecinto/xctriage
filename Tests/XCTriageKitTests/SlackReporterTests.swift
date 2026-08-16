import XCTest
@testable import XCTriageKit

// Reuses StubURLProtocol from ClaudeClassifierTests.swift (same test target).
final class SlackReporterTests: XCTestCase {

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func sampleReport() -> TriageReport {
        TriageReport(
            buildID: "build-42",
            source: .xcodebuild,
            classification: ClassificationResult(
                category: .compilationError,
                confidence: 0.9,
                failureSites: [
                    FailureSite(file: "Foo.swift", line: 10, column: nil, testName: nil, errorMessage: "unresolved identifier")
                ],
                summary: "unresolved identifier 'Bar'",
                suggestedFix: "import the missing module"
            ),
            rawLogLines: 50,
            durationMS: 12
        )
    }

    func test_report_succeedsOn200() async throws {
        StubURLProtocol.responseData = Data()
        StubURLProtocol.statusCode = 200

        let reporter = SlackReporter(webhookURL: URL(string: "https://hooks.slack.test/webhook")!, session: stubbedSession())
        try await reporter.report(sampleReport())
        // No throw = success.
    }

    // Regression test: a failed webhook POST used to surface as
    // TriageError.claudeAPIError(0, ...): the wrong error case, and a
    // hardcoded 0 that discarded the real HTTP status.
    // Slack rejects an entire message if any single mrkdwn text block exceeds
    // 3000 characters — a long Claude-generated summary/fix would previously
    // make the whole notification fail to deliver instead of just being long.
    func test_report_truncatesTextBlocksToSlacksLimit() async throws {
        StubURLProtocol.responseData = Data()
        StubURLProtocol.statusCode = 200

        let longText = String(repeating: "a", count: 5_000)
        let report = TriageReport(
            buildID: "build-42",
            source: .xcodebuild,
            classification: ClassificationResult(
                category: .compilationError,
                confidence: 0.9,
                failureSites: [
                    FailureSite(file: "Foo.swift", line: 10, column: nil, testName: nil, errorMessage: longText)
                ],
                summary: longText,
                suggestedFix: longText
            ),
            rawLogLines: 50,
            durationMS: 12
        )

        let reporter = SlackReporter(webhookURL: URL(string: "https://hooks.slack.test/webhook")!, session: stubbedSession())
        try await reporter.report(report)

        let body = try XCTUnwrap(StubURLProtocol.capturedRequestBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let blocks = try XCTUnwrap(json?["blocks"] as? [[String: Any]])

        for block in blocks {
            if let text = block["text"] as? [String: Any], let value = text["text"] as? String {
                XCTAssertLessThanOrEqual(value.count, 3000, "a single mrkdwn text block over 3000 chars gets the whole Slack message rejected")
            }
            if let fields = block["fields"] as? [[String: Any]] {
                for field in fields {
                    if let value = field["text"] as? String {
                        XCTAssertLessThanOrEqual(value.count, 3000)
                    }
                }
            }
        }
    }

    func test_report_throwsSlackWebhookFailedWithRealStatusCode_onNon200() async {
        StubURLProtocol.responseData = Data("invalid_payload".utf8)
        StubURLProtocol.statusCode = 400

        let reporter = SlackReporter(webhookURL: URL(string: "https://hooks.slack.test/webhook")!, session: stubbedSession())
        do {
            try await reporter.report(sampleReport())
            XCTFail("expected slackWebhookFailed for non-200 response")
        } catch TriageError.slackWebhookFailed(let status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("expected TriageError.slackWebhookFailed, got \(error)")
        }
    }
}

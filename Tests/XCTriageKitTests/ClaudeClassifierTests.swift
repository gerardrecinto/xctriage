import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XCTriageKit

// Stubs URLSession responses so I can exercise ClaudeClassifier without a
// real network call. Registered per-test via a dedicated URLSessionConfiguration.
final class StubURLProtocol: URLProtocol {
    // Test-only fixture state, set synchronously before each stubbed request
    // and never mutated concurrently, so opting out of strict checking is safe.
    nonisolated(unsafe) static var responseData: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    // Captures the outgoing request body so a test can assert on what was
    // actually sent, not just how the response was handled.
    nonisolated(unsafe) static var capturedRequestBody: Data?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession commonly converts a URLRequest's httpBody Data into an
        // httpBodyStream by the time URLProtocol sees it, so request.httpBody
        // alone is often nil here — read the stream when that happens.
        if let body = request.httpBody {
            Self.capturedRequestBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            Self.capturedRequestBody = data
        } else {
            Self.capturedRequestBody = nil
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ClaudeClassifierTests: XCTestCase {

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func test_classify_decodesWellFormedResponse() async throws {
        let responseJSON = """
        {"category":"compilation_error","confidence":0.9,"summary":"bad import",
         "suggested_fix":"check imports","failure_sites":[{"file":"Foo.swift","line":10,
         "test_name":null,"error_message":"unresolved identifier"}]}
        """
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": responseJSON]
            ]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        let entry = LogEntry(lineNumber: 1, level: .error, message: "boom", raw: "boom")
        let result = try await classifier.classify([entry])

        XCTAssertEqual(result.category, .compilationError)
        XCTAssertEqual(result.confidence, 0.9)
        XCTAssertTrue(result.llmUsed)
        XCTAssertEqual(result.failureSites.first?.file, "Foo.swift")
        XCTAssertEqual(result.failureSites.first?.line, 10)
    }

    func test_classify_stripsMarkdownCodeFence() async throws {
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": "```json\n{\"category\":\"timeout\",\"confidence\":0.7,\"summary\":\"slow\"}\n```"]
            ]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        let result = try await classifier.classify([LogEntry(lineNumber: 1, level: .error, message: "boom", raw: "boom")])

        XCTAssertEqual(result.category, .timeout)
    }

    func test_classify_throwsOnNonJSONResponseBody() async {
        StubURLProtocol.responseData = Data("not json at all".utf8)
        StubURLProtocol.statusCode = 200

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        do {
            _ = try await classifier.classify([LogEntry(lineNumber: 1, level: .error, message: "boom", raw: "boom")])
            XCTFail("expected parseError for malformed API response")
        } catch TriageError.parseError {
            // expected: malformed upstream JSON must not crash the process
        } catch {
            XCTFail("expected TriageError.parseError, got \(error)")
        }
    }

    func test_classify_throwsOnHTTPErrorStatus() async {
        StubURLProtocol.responseData = Data("{\"error\":\"rate limited\"}".utf8)
        StubURLProtocol.statusCode = 429

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        do {
            _ = try await classifier.classify([LogEntry(lineNumber: 1, level: .error, message: "boom", raw: "boom")])
            XCTFail("expected claudeAPIError for non-200 response")
        } catch TriageError.claudeAPIError(let code, _) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("expected TriageError.claudeAPIError, got \(error)")
        }
    }

    func test_classify_fallsBackToUnknownCategoryForUnrecognizedString() async throws {
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": "{\"category\":\"not_a_real_category\",\"confidence\":0.5,\"summary\":\"?\"}"]
            ]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        let result = try await classifier.classify([LogEntry(lineNumber: 1, level: .error, message: "boom", raw: "boom")])

        XCTAssertEqual(result.category, .unknown)
    }

    // MARK: - promptText / redaction boundary

    func test_classifyPromptText_sendsExactTextGiven() async throws {
        let payload: [String: Any] = [
            "content": [["type": "text", "text": "{\"category\":\"timeout\",\"confidence\":0.7,\"summary\":\"slow\"}"]]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200
        StubURLProtocol.capturedRequestBody = nil

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        _ = try await classifier.classify(promptText: "hand-built prompt text")

        let body = try XCTUnwrap(StubURLProtocol.capturedRequestBody)
        let sent = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(sent.contains("hand-built prompt text"))
    }

    func test_classify_redactedSecretNeverReachesTheRequestBody() async throws {
        let payload: [String: Any] = [
            "content": [["type": "text", "text": "{\"category\":\"infra_failure\",\"confidence\":0.8,\"summary\":\"leaked token\"}"]]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200
        StubURLProtocol.capturedRequestBody = nil

        let secretLog = "error: auth failed with token ghp_ABCDEFGHIJ0123456789abcdefghij0123"
        let redaction = Redactor().redact(secretLog)
        XCTAssertFalse(redaction.matches.isEmpty)

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        _ = try await classifier.classify(promptText: redaction.redactedText)

        let body = try XCTUnwrap(StubURLProtocol.capturedRequestBody)
        let sent = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(sent.contains("ghp_ABCDEFGHIJ0123456789abcdefghij0123"))
        XCTAssertTrue(sent.contains("[REDACTED:github-token]"))
    }

    func test_buildPromptText_matchesWhatClassifySends() async throws {
        let payload: [String: Any] = [
            "content": [["type": "text", "text": "{\"category\":\"timeout\",\"confidence\":0.7,\"summary\":\"slow\"}"]]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200
        StubURLProtocol.capturedRequestBody = nil

        let entries = [LogEntry(lineNumber: 1, level: .error, message: "distinctive marker line", raw: "")]
        let preview = ClaudeClassifier.buildPromptText(entries)
        XCTAssertEqual(preview, "distinctive marker line")

        let classifier = ClaudeClassifier(apiKey: "test-key", session: stubbedSession())
        _ = try await classifier.classify(entries)

        let body = try XCTUnwrap(StubURLProtocol.capturedRequestBody)
        let sent = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(sent.contains(preview))
    }
}

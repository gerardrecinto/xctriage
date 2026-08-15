import XCTest
@testable import XCTriageKit

final class PatchGeneratorTests: XCTestCase {

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func site(file: String = "Foo.swift", testName: String = "FooTests.test_a") -> FailureSite {
        FailureSite(file: file, line: 10, column: nil, testName: testName, errorMessage: "unresolved identifier 'Bar'")
    }

    func test_proposePatch_decodesWellFormedResponse() async throws {
        let responseJSON = """
        {"file_path":"Sources/Foo.swift","unified_diff":"--- a/Foo.swift\\n+++ b/Foo.swift\\n@@ -1 +1 @@\\n-import Bar\\n+import Baz",
         "rationale":"Bar was renamed to Baz upstream","confidence":0.82}
        """
        let payload: [String: Any] = ["content": [["type": "text", "text": responseJSON]]]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200

        let generator = PatchGenerator(apiKey: "test-key", session: stubbedSession())
        let proposal = try await generator.proposePatch(
            category: .compilationError,
            failureSite: site(),
            fileContents: "import Bar\nstruct Foo {}"
        )

        XCTAssertEqual(proposal.filePath, "Sources/Foo.swift")
        XCTAssertTrue(proposal.unifiedDiff.contains("+import Baz"))
        XCTAssertEqual(proposal.rationale, "Bar was renamed to Baz upstream")
        XCTAssertEqual(proposal.confidence, 0.82)
    }

    func test_proposePatch_stripsMarkdownCodeFence() async throws {
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": "```json\n{\"file_path\":\"Foo.swift\",\"unified_diff\":\"diff\",\"rationale\":\"r\",\"confidence\":0.5}\n```"]
            ]
        ]
        StubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.statusCode = 200

        let generator = PatchGenerator(apiKey: "test-key", session: stubbedSession())
        let proposal = try await generator.proposePatch(category: .compilationError, failureSite: site(), fileContents: "x")

        XCTAssertEqual(proposal.filePath, "Foo.swift")
    }

    func test_proposePatch_throwsOnNonJSONResponseBody() async {
        StubURLProtocol.responseData = Data("not json at all".utf8)
        StubURLProtocol.statusCode = 200

        let generator = PatchGenerator(apiKey: "test-key", session: stubbedSession())
        do {
            _ = try await generator.proposePatch(category: .compilationError, failureSite: site(), fileContents: "x")
            XCTFail("expected parseError for malformed API response")
        } catch TriageError.parseError {
            // expected
        } catch {
            XCTFail("expected TriageError.parseError, got \(error)")
        }
    }

    func test_proposePatch_throwsOnHTTPErrorStatus() async {
        StubURLProtocol.responseData = Data("{\"error\":\"rate limited\"}".utf8)
        StubURLProtocol.statusCode = 429

        let generator = PatchGenerator(apiKey: "test-key", session: stubbedSession())
        do {
            _ = try await generator.proposePatch(category: .compilationError, failureSite: site(), fileContents: "x")
            XCTFail("expected claudeAPIError for non-200 response")
        } catch TriageError.claudeAPIError(let code, _) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("expected TriageError.claudeAPIError, got \(error)")
        }
    }
}

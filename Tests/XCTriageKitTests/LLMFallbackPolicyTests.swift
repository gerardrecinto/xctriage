import XCTest
@testable import XCTriageKit

final class LLMFallbackPolicyTests: XCTestCase {

    func test_shouldUseLLM_falseWithoutAPIKey_evenWithLLMAlways() {
        let result = LLMFallbackPolicy.shouldUseLLM(
            hasAPIKey: false, llmAlways: true, llmRequested: true, confidence: 0.1, threshold: 0.60
        )
        XCTAssertFalse(result)
    }

    func test_shouldUseLLM_trueWithLLMAlways_regardlessOfConfidence() {
        let result = LLMFallbackPolicy.shouldUseLLM(
            hasAPIKey: true, llmAlways: true, llmRequested: false, confidence: 0.99, threshold: 0.60
        )
        XCTAssertTrue(result)
    }

    func test_shouldUseLLM_trueWhenRequestedAndBelowThreshold() {
        let result = LLMFallbackPolicy.shouldUseLLM(
            hasAPIKey: true, llmAlways: false, llmRequested: true, confidence: 0.40, threshold: 0.60
        )
        XCTAssertTrue(result)
    }

    func test_shouldUseLLM_falseWhenRequestedButAtOrAboveThreshold() {
        let result = LLMFallbackPolicy.shouldUseLLM(
            hasAPIKey: true, llmAlways: false, llmRequested: true, confidence: 0.60, threshold: 0.60
        )
        XCTAssertFalse(result)
    }

    func test_shouldUseLLM_falseWhenNeitherFlagSet() {
        let result = LLMFallbackPolicy.shouldUseLLM(
            hasAPIKey: true, llmAlways: false, llmRequested: false, confidence: 0.1, threshold: 0.60
        )
        XCTAssertFalse(result)
    }
}

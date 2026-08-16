import Foundation

// The `--llm`/`--llm-always` fallback decision, extracted so both of
// `xctriage analyze`'s input paths (build log and .xcresult) apply it
// identically. Before this existed, the .xcresult branch in Analyze.run()
// never consulted these flags at all — it always used only RuleClassifier,
// silently ignoring `--llm`/`--llm-always` for that input type, unlike the
// build-log path a few lines below it.
public enum LLMFallbackPolicy {
    public static func shouldUseLLM(
        hasAPIKey: Bool,
        llmAlways: Bool,
        llmRequested: Bool,
        confidence: Double,
        threshold: Double
    ) -> Bool {
        guard hasAPIKey else { return false }
        if llmAlways { return true }
        return llmRequested && confidence < threshold
    }
}

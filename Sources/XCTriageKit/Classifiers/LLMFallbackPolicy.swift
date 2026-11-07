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

    // The exact text that leaves the machine for a classification call.
    // Redaction is on by default; `--no-redact` is the only way to send the
    // raw log. Kept here so the CLI and the tests share one code path.
    public static func promptPayload(
        entries: [LogEntry],
        redact: Bool
    ) -> (text: String, redaction: RedactionResult?) {
        let raw = ClaudeClassifier.buildPromptText(entries)
        guard redact else { return (raw, nil) }
        let result = Redactor().redact(raw)
        return (result.redactedText, result)
    }
}

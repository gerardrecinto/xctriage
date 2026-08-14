import Foundation

public struct JSONReporter: Sendable {

    private let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.write = write
    }

    public func report(_ triage: TriageReport) throws {
        let c = triage.classification
        let iso = ISO8601DateFormatter()

        let obj: [String: Any] = [
            "build_id": triage.buildID ?? NSNull(),
            "source": triage.source.rawValue,
            "timestamp": iso.string(from: triage.timestamp),
            "duration_ms": triage.durationMS,
            "raw_log_lines": triage.rawLogLines,
            "classification": [
                "category": c.category.rawValue,
                "confidence": c.confidence,
                "summary": c.summary,
                "suggested_fix": c.suggestedFix ?? NSNull(),
                "llm_used": c.llmUsed,
                "failure_sites": c.failureSites.map { s -> [String: Any] in
                    [
                        "file": s.file ?? NSNull(),
                        "line": s.line ?? NSNull(),
                        "column": s.column ?? NSNull(),
                        "test_name": s.testName ?? NSNull(),
                        "error_message": s.errorMessage,
                    ]
                },
            ] as [String: Any],
            "flaky_test_scores": triage.flakyTestScores,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        write(String(data: data, encoding: .utf8) ?? "{}")
    }
}

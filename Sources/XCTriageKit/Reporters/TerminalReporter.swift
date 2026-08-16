import Foundation

// ANSI terminal reporter with color-coded output by failure category
public struct TerminalReporter: Sendable {

    private let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.write = write
    }

    public func report(_ triage: TriageReport) {
        let c = triage.classification
        let color = categoryColor(c.category)
        let icon = categoryIcon(c.category)

        writeln()
        writeln(bold("────────────────────────────────────────────────────────────"))
        writeln(bold("  xctriage"))
        writeln(bold("────────────────────────────────────────────────────────────"))
        writeln(colored(bold("  \(icon)  \(c.category.displayName)"), color: color))

        if let id = triage.buildID { writeln("  \(dim("build:"))  \(id)") }
        writeln("  \(dim("source:")) \(triage.source.rawValue)")
        writeln("  \(dim("lines:"))  \(triage.rawLogLines)")
        writeln(String(format: "  \(dim("time:"))   %.0fms", triage.durationMS))
        writeln()

        writeln(colored("  CONFIDENCE", color: .cyan))
        writeln("  \(confidenceBar(c.confidence))")
        writeln()

        writeln(colored("  ROOT CAUSE", color: .cyan))
        writeln("  \(c.summary)")
        writeln()

        if let fix = c.suggestedFix {
            writeln(colored("  SUGGESTED FIX", color: .cyan))
            writeln("  \(fix)")
            writeln()
        }

        if !c.failureSites.isEmpty {
            writeln(colored("  FAILURE SITES", color: .cyan))
            for site in c.failureSites.prefix(5) {
                writeln("  \(colored(site.locationDescription, color: .blue))")
                writeln("    \(colored(site.errorMessage, color: .red))")
            }
            if c.failureSites.count > 5 {
                writeln(dim("  ... and \(c.failureSites.count - 5) more"))
            }
            writeln()
        }

        if !triage.flakyTestScores.isEmpty {
            writeln(colored("  FLAKY TEST TRACKER (90-day window)", color: .cyan))
            for (name, score) in triage.flakyTestScores.sorted(by: { $0.value > $1.value }).prefix(8) {
                let bar = FlakyBarFormatter.bar(score: score)
                let scoreColor: ANSIColor = score >= 0.70 ? .red : score >= 0.40 ? .yellow : .green
                writeln("  \(colored(bar, color: scoreColor)) \(FlakyBarFormatter.scoreLabel(score))  \(dim(name))")
            }
            writeln()
        }

        let method = c.llmUsed ? "Claude \(triage.source.rawValue)" : "rule-based"
        writeln(dim("  (analysis: \(method))"))
        writeln(bold("────────────────────────────────────────────────────────────"))
        writeln()
    }

    // MARK: ANSI helpers

    private enum ANSIColor { case red, yellow, green, cyan, blue, magenta }

    private func colored(_ text: String, color: ANSIColor) -> String {
        let code: String
        switch color {
        case .red:     code = "\u{001B}[91m"
        case .yellow:  code = "\u{001B}[93m"
        case .green:   code = "\u{001B}[92m"
        case .cyan:    code = "\u{001B}[96m"
        case .blue:    code = "\u{001B}[94m"
        case .magenta: code = "\u{001B}[95m"
        }
        return "\(code)\(text)\u{001B}[0m"
    }

    private func bold(_ text: String) -> String { "\u{001B}[1m\(text)\u{001B}[0m" }
    private func dim(_ text: String) -> String { "\u{001B}[2m\(text)\u{001B}[0m" }

    // confidence is only documented "0.0-1.0", never enforced — ClaudeClassifier
    // parses it straight out of untrusted LLM JSON. Clamp the bar (matching
    // FlakyBarFormatter's identical clamp) so an out-of-range value degrades
    // to a full/empty bar instead of crashing on a negative repeat count;
    // the raw percentage is still shown so an out-of-range value stays visible.
    private func confidenceBar(_ confidence: Double, width: Int = 20) -> String {
        let clamped = min(max(confidence, 0), 1)
        let filled = Int((clamped * Double(width)).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let color: ANSIColor = confidence >= 0.80 ? .green : confidence >= 0.60 ? .yellow : .red
        return "\(colored(bar, color: color)) \(Int(confidence * 100))%"
    }

    private func categoryColor(_ category: FailureCategory) -> ANSIColor {
        switch category {
        case .compilationError, .resourceExhaustion, .infraFailure: return .red
        case .testFailure, .dependencyFailure, .timeout: return .yellow
        case .flakyTest: return .magenta
        case .unknown: return .cyan
        }
    }

    private func categoryIcon(_ category: FailureCategory) -> String {
        switch category {
        case .compilationError, .testFailure: return "✗"
        case .flakyTest: return "~"
        case .resourceExhaustion, .infraFailure: return "!"
        case .dependencyFailure: return "?"
        case .timeout: return "T"
        case .unknown: return "?"
        }
    }

    private func writeln(_ line: String = "") {
        write(line)
    }
}

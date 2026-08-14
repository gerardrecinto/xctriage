import Foundation

// Shared block-bar rendering for flaky test scores. Used by both TerminalReporter
// (colored, wrapped in ANSI codes) and the `xctriage flaky` CLI command (plain).
// Score formatting goes through String(format:) with a fixed literal template only;
// caller-supplied strings (test names) are never interpolated into a format string,
// since a name containing "%" would otherwise be misparsed as a format specifier.
public enum FlakyBarFormatter {
    public static func bar(score: Double, width: Int = 10, filled: Character = "\u{2588}", empty: Character = "\u{2591}") -> String {
        let clamped = min(max(score, 0), 1)
        let filledCount = Int((clamped * Double(width)).rounded())
        return String(repeating: filled, count: filledCount) + String(repeating: empty, count: width - filledCount)
    }

    public static func scoreLabel(_ score: Double) -> String {
        String(format: "%.2f", score)
    }

    public static func row(name: String, score: Double, width: Int = 10) -> String {
        "\(scoreLabel(score))   \(bar(score: score, width: width))  \(name)"
    }
}

import Foundation

// Both ClaudeClassifier and PatchGenerator ask Claude for JSON-only output,
// but a model can still wrap its answer in a markdown code fence anyway.
// Splitting on "\n" and dropping the first/last line breaks when the fence
// markers themselves have no newline around them (a single-line response) —
// dropFirst() already empties a one-element array, so dropLast() has
// nothing left and the whole response is lost. This strips by marker
// position instead, so it works whether or not the response spans one line.
public enum MarkdownJSONFenceStripper {
    public static func strip(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }

        if let firstNewline = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: firstNewline)...])
        } else {
            result.removeFirst(3)
        }
        if result.hasSuffix("```") {
            result.removeLast(3)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

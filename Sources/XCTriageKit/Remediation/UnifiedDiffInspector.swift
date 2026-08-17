import Foundation

// Deterministically verifies a PatchProposal's claimed file_path actually
// matches the file its own unified_diff targets. Nothing else in this
// pipeline checked this: RemediationPolicy validates proposal.filePath (an
// LLM-echoed string), while `git apply` acts on whatever the diff's own
// `+++ b/...` header says. A response where those two disagree would pass
// every existing gate — the forbidden-path check validates the claimed
// path while the actual write lands wherever the diff really points.
public enum UnifiedDiffInspector {
    // Reads the "new file" side (+++) of a unified diff header, since that's
    // the version `git apply` actually writes to disk. Handles both the
    // standard git a/ b/ prefix style and the --no-prefix style, and strips
    // a trailing tab-separated timestamp some diff generators append.
    public static func targetPath(in diff: String) -> String? {
        guard let line = diff.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("+++ ") })
        else { return nil }

        var path = line.dropFirst("+++ ".count)
        if let tabIndex = path.firstIndex(of: "\t") {
            path = path[path.startIndex..<tabIndex]
        }
        var pathString = String(path).trimmingCharacters(in: .whitespaces)
        if pathString.hasPrefix("b/") || pathString.hasPrefix("a/") {
            pathString.removeFirst(2)
        }
        return pathString.isEmpty ? nil : pathString
    }

    // Fails closed: an unparseable diff can't be verified, so it's treated
    // as a mismatch rather than assumed safe.
    public static func matchesClaimedPath(_ claimedPath: String, diff: String) -> Bool {
        guard let actual = targetPath(in: diff) else { return false }
        return actual == claimedPath
    }
}

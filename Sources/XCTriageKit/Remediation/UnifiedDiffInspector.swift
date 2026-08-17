import Foundation

// Deterministically verifies a PatchProposal's claimed file_path actually
// matches the file its own unified_diff targets. Nothing else in this
// pipeline checked this: RemediationPolicy validates proposal.filePath (an
// LLM-echoed string), while `git apply` acts on whatever the diff's own
// `+++ b/...` header says. A response where those two disagree would pass
// every existing gate — the forbidden-path check validates the claimed
// path while the actual write lands wherever the diff really points.
public enum UnifiedDiffInspector {
    // Reads the "new file" side (+++) of a unified diff's FIRST header only.
    // A unified_diff string can legitimately contain more than one file's
    // header block concatenated together — verified empirically with real
    // git: `git apply` on a diff with two `--- a/...`/`+++ b/...` blocks
    // applies BOTH files' changes, exit 0, no complaint. Use allTargetPaths
    // for anything that needs to know about every file a diff touches;
    // this only exists for the (rarer) case where the first file
    // specifically is what matters.
    public static func targetPath(in diff: String) -> String? {
        allTargetPaths(in: diff).first
    }

    // Every "new file" side (+++) path in the diff, in order, one per file
    // header block. Handles both the standard git a/ b/ prefix style and
    // the --no-prefix style, and strips a trailing tab-separated timestamp
    // some diff generators append.
    public static func allTargetPaths(in diff: String) -> [String] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+++ ") }
            .compactMap { line -> String? in
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
    }

    // Fails closed: an unparseable diff, or a diff touching anything other
    // than EXACTLY the one claimed file, is treated as a mismatch rather
    // than assumed safe. Checking only the first target (the original,
    // narrower version of this check) would have let a diff that also
    // smuggles in hunks for a second, possibly-forbidden file pass as long
    // as its first file header matched the claim.
    public static func matchesClaimedPath(_ claimedPath: String, diff: String) -> Bool {
        allTargetPaths(in: diff) == [claimedPath]
    }
}

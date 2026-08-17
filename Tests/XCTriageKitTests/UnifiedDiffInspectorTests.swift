import XCTest
@testable import XCTriageKit

final class UnifiedDiffInspectorTests: XCTestCase {

    // Nothing in this codebase previously verified that a PatchProposal's
    // claimed `file_path` actually matches the file its own `unified_diff`
    // targets — RemediationPolicy checks `proposal.filePath` (an LLM-echoed
    // string), while `git apply` acts on whatever the diff's own `+++ b/...`
    // header says. An LLM response where those two disagree would sail past
    // every existing gate: the forbidden-path check validates the claimed
    // path while the actual write lands somewhere else entirely.

    func test_targetPath_extractsFromStandardGitStyleHeader() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        """
        XCTAssertEqual(UnifiedDiffInspector.targetPath(in: diff), "Sources/Foo.swift")
    }

    func test_targetPath_handlesNoPrefixStyle() {
        // git apply --no-prefix / some diff tools omit the a/ b/ prefixes.
        let diff = """
        --- Sources/Foo.swift
        +++ Sources/Foo.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        """
        XCTAssertEqual(UnifiedDiffInspector.targetPath(in: diff), "Sources/Foo.swift")
    }

    func test_targetPath_stripsTrailingTabTimestamp() {
        // Some diff generators append a tab-separated timestamp after the path.
        let diff = """
        --- a/Sources/Foo.swift\t2024-01-01 00:00:00
        +++ b/Sources/Foo.swift\t2024-01-01 00:00:01
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        """
        XCTAssertEqual(UnifiedDiffInspector.targetPath(in: diff), "Sources/Foo.swift")
    }

    func test_targetPath_returnsNilForDiffWithNoHeader() {
        XCTAssertNil(UnifiedDiffInspector.targetPath(in: "not a diff at all"))
    }

    func test_targetPath_returnsNilForEmptyDiff() {
        XCTAssertNil(UnifiedDiffInspector.targetPath(in: ""))
    }

    func test_matchesClaimedPath_trueWhenConsistent() {
        let diff = "--- a/Sources/Foo.swift\n+++ b/Sources/Foo.swift\n@@ -1 +1 @@\n-a\n+b"
        XCTAssertTrue(UnifiedDiffInspector.matchesClaimedPath("Sources/Foo.swift", diff: diff))
    }

    // The exact scenario this exists to catch: PatchProposal.filePath says
    // one file, but the diff itself would actually modify a different one.
    func test_matchesClaimedPath_falseWhenDiffTargetsADifferentFile() {
        let diff = "--- a/Sources/Bar.swift\n+++ b/Sources/Bar.swift\n@@ -1 +1 @@\n-a\n+b"
        XCTAssertFalse(UnifiedDiffInspector.matchesClaimedPath("Sources/Foo.swift", diff: diff))
    }

    func test_matchesClaimedPath_falseWhenDiffHasNoParsableHeader() {
        // Fail closed: an unparseable diff can't be verified, so treat it as
        // a mismatch rather than assuming it's fine.
        XCTAssertFalse(UnifiedDiffInspector.matchesClaimedPath("Sources/Foo.swift", diff: "garbage"))
    }

    // The gap this closes: a single unified_diff STRING can legitimately
    // contain more than one file's header block concatenated together —
    // verified empirically with real git: `git apply` on a diff with two
    // `--- a/...`/`+++ b/...` blocks applies BOTH files' changes, exit 0, no
    // complaint. RemediationPolicy.isPatchAllowed is always called with a
    // hardcoded `[proposal.filePath]` single-element array, so its
    // maxFilesChanged check is vacuous — it never actually counts what the
    // diff touches. The original matchesClaimedPath only inspected the
    // FIRST `+++` line, so a diff claiming to touch only an allowed file
    // while ALSO smuggling in hunks for a forbidden file (e.g.
    // RemediationPolicy.swift itself) would pass every existing gate.
    func test_targetPath_onlyReturnsFirstFile_documentingTheGapAllTargetPathsCloses() {
        let smuggledDiff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        --- a/Sources/Policy/RemediationPolicy.swift
        +++ b/Sources/Policy/RemediationPolicy.swift
        @@ -1 +1 @@
        -forbid this
        +allow this
        """
        // targetPath alone can't see the smuggled second file — that's
        // exactly why matchesClaimedPath must use allTargetPaths, not this.
        XCTAssertEqual(UnifiedDiffInspector.targetPath(in: smuggledDiff), "Sources/Foo.swift")
    }

    func test_allTargetPaths_findsEveryFileHeaderNotJustTheFirst() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        --- a/Sources/Bar.swift
        +++ b/Sources/Bar.swift
        @@ -1 +1 @@
        -let y = 1
        +let y = 2
        """
        XCTAssertEqual(UnifiedDiffInspector.allTargetPaths(in: diff), ["Sources/Foo.swift", "Sources/Bar.swift"])
    }

    func test_matchesClaimedPath_falseWhenDiffSmugglesASecondFile() {
        let smuggledDiff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        --- a/Sources/Policy/RemediationPolicy.swift
        +++ b/Sources/Policy/RemediationPolicy.swift
        @@ -1 +1 @@
        -forbid this
        +allow this
        """
        XCTAssertFalse(
            UnifiedDiffInspector.matchesClaimedPath("Sources/Foo.swift", diff: smuggledDiff),
            "a diff touching a second file must not pass just because the FIRST file matches the claim"
        )
    }
}

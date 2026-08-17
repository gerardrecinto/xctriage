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
}

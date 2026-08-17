import XCTest
@testable import XCTriageKit

final class FailureSitePathResolverTests: XCTestCase {

    // Real xcodebuild/swift build diagnostics report absolute paths
    // (verified against real `swift build` output, not assumed) —
    // "/Users/runner/work/x/x/Sources/Foo.swift:42:10: error: ...". The
    // previous code joined that directly onto repoRoot with
    // NSString.appendingPathComponent, which does not special-case an
    // absolute argument — "." + "/Users/.../Foo.swift" produced the
    // nonsensical "./Users/.../Foo.swift", which resolves to a path that
    // does not exist, so `xctriage remediate` failed with fileNotFound on
    // every real compiler-reported failure. Reproduced end-to-end against
    // the real binary and a real `swift build` compile error before this
    // fix existed.
    func test_resolve_usesAbsoluteFileAsIs_ignoringRepoRoot() {
        let resolved = FailureSitePathResolver.resolve(
            file: "/Users/runner/work/xctriage/xctriage/Sources/XCTriageKit/Foo.swift",
            repoRoot: "."
        )
        XCTAssertEqual(resolved, "/Users/runner/work/xctriage/xctriage/Sources/XCTriageKit/Foo.swift")
    }

    func test_resolve_joinsRelativeFileWithRepoRoot() {
        let resolved = FailureSitePathResolver.resolve(file: "Sources/Foo.swift", repoRoot: "/repo")
        XCTAssertEqual(resolved, "/repo/Sources/Foo.swift")
    }

    func test_resolve_absoluteFileIgnoresNonDefaultRepoRoot() {
        // Not just the "." default — an absolute file path must win over
        // ANY repoRoot, since it's already a complete, correct path.
        let resolved = FailureSitePathResolver.resolve(
            file: "/private/tmp/pathprobe/Sources/pathprobe/main.swift",
            repoRoot: "/Users/dev/some-other-checkout"
        )
        XCTAssertEqual(resolved, "/private/tmp/pathprobe/Sources/pathprobe/main.swift")
    }

    // Second half of the same bug class: PatchGenerator used to be shown the
    // absolute resolved path in its prompt (`File: /Users/x/Sources/Foo.swift`),
    // with no instruction to use a different format in its response. An LLM
    // asked to propose a unified diff for a file it was shown at an absolute
    // path very plausibly mirrors that same absolute path into the diff's
    // `--- a/...`/`+++ b/...` headers — and `git apply` REJECTS an absolute
    // path in a diff header outright. Verified empirically: `git apply` on a
    // diff with `--- a//tmp/x/Foo.swift` fails with "error: invalid path
    // '/tmp/x/Foo.swift'", exit 128, against a real git repo. Computing a
    // clean repo-relative path to show the LLM instead (this function) closes
    // that off at the source, rather than hoping prompt wording alone
    // prevents an absolute path from ever reaching the diff.
    func test_repoRelativePath_stripsRepoRootFromResolvedFile() {
        let relative = FailureSitePathResolver.repoRelativePath(
            forResolvedFile: "/Users/runner/work/xctriage/xctriage/Sources/XCTriageKit/Foo.swift",
            repoRoot: "/Users/runner/work/xctriage/xctriage"
        )
        XCTAssertEqual(relative, "Sources/XCTriageKit/Foo.swift")
    }

    func test_repoRelativePath_handlesRepoRootWithTrailingSlash() {
        let relative = FailureSitePathResolver.repoRelativePath(
            forResolvedFile: "/repo/Sources/Foo.swift",
            repoRoot: "/repo/"
        )
        XCTAssertEqual(relative, "Sources/Foo.swift")
    }

    func test_repoRelativePath_fallsBackToResolvedFileWhenNotUnderRepoRoot() {
        // A failure in, say, an SDK header outside the checkout has no
        // sensible relative path — fall back to the resolved path rather
        // than producing something nonsensical. This tool can't patch a
        // file outside the repo either way (git apply would fail against
        // it regardless), so this is an inherent limit, not a new gap.
        let relative = FailureSitePathResolver.repoRelativePath(
            forResolvedFile: "/opt/sdk/Headers/Foo.h",
            repoRoot: "/Users/dev/repo"
        )
        XCTAssertEqual(relative, "/opt/sdk/Headers/Foo.h")
    }
}

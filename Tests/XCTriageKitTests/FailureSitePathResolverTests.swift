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
}

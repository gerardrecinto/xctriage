import Foundation

// Resolves a FailureSite's reported file path against repoRoot for reading
// the file's contents. Real xcodebuild/swift build diagnostics report
// absolute paths (verified against real `swift build` output), and
// XCResultParser's file:// URL parsing produces absolute paths too — an
// absolute `file` has to be used as-is, never joined onto repoRoot.
// NSString.appendingPathComponent does not special-case an absolute
// argument: `"." + "/Users/x/Foo.swift"` produces the nonsensical
// "./Users/x/Foo.swift", which resolves to a path that does not exist.
public enum FailureSitePathResolver {
    public static func resolve(file: String, repoRoot: String) -> String {
        // isDirectory: true matters — without it, URL(fileURLWithPath:) can't
        // tell repoRoot is a directory and resolves a relative `file` as a
        // SIBLING of repoRoot (replacing its last path component) instead of
        // a child under it, verified empirically before landing this fix.
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        return URL(fileURLWithPath: file, relativeTo: base).path
    }
}

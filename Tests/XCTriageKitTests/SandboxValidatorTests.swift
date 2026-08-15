import XCTest
@testable import XCTriageKit

final class SandboxValidatorTests: XCTestCase {

    // Fake `git`/`swift` standing in for the real toolchain, same rationale as
    // XCResultParserTests' fake xcrun: exercise Process/Pipe handling without
    // depending on a real git worktree or swift toolchain in CI. Dispatches on
    // $1 (the subcommand) so one script can play both tools across a run.
    private func makeFakeTool(exitCodes: [String: Int32], output: String = "") throws -> String {
        let path = NSTemporaryDirectory() + "fake-tool-\(UUID().uuidString).sh"
        let cases = exitCodes.map { cmd, code in
            "  \(cmd)) echo '\(output)'; exit \(code) ;;"
        }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        case "$1" in
        \(cases)
          *) exit 0 ;;
        esac
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func proposal() -> PatchProposal {
        PatchProposal(filePath: "Foo.swift", unifiedDiff: "--- a/Foo.swift\n+++ b/Foo.swift\n", rationale: "r", confidence: 0.8)
    }

    func test_validate_returnsPassedWhenApplyBuildAndTestAllSucceed() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 0, "apply": 0, "remove": 0])
        let swift = try makeFakeTool(exitCodes: ["build": 0, "test": 0])
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let result = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory())

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.applied)
        XCTAssertTrue(result.buildSucceeded)
        XCTAssertTrue(result.testSucceeded)
    }

    func test_validate_stopsAtWorktreeFailureWithoutApplyingOrBuilding() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 1], output: "no space left on device")
        let swift = try makeFakeTool(exitCodes: ["build": 0, "test": 0])
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let result = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory())

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.applied)
        XCTAssertTrue(result.output.contains("no space left on device"))
    }

    func test_validate_stopsAtApplyFailureWithoutBuilding() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 0, "apply": 1, "remove": 0], output: "patch does not apply")
        let swift = try makeFakeTool(exitCodes: ["build": 0, "test": 0])
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let result = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory())

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.applied)
        XCTAssertFalse(result.buildSucceeded)
    }

    func test_validate_reportsBuildFailureSeparatelyFromApplyFailure() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 0, "apply": 0, "remove": 0])
        let swift = try makeFakeTool(exitCodes: ["build": 1, "test": 0], output: "error: cannot find type 'Foo'")
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let result = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory())

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.applied)
        XCTAssertFalse(result.buildSucceeded)
        XCTAssertFalse(result.testSucceeded)
    }

    func test_validate_reportsTestFailureWhenBuildSucceedsButTestFails() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 0, "apply": 0, "remove": 0])
        let swift = try makeFakeTool(exitCodes: ["build": 0, "test": 1], output: "XCTAssertEqual failed")
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let result = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory())

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.applied)
        XCTAssertTrue(result.buildSucceeded)
        XCTAssertFalse(result.testSucceeded)
    }
}

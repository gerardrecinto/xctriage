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

    // Stands in for a hung `swift build`/`swift test`: sleeps far longer than
    // the timeout under test, so a passing test proves validate() actually
    // gave up early rather than just happening to finish fast.
    private func makeHangingTool(hangingOn command: String, sleepSeconds: Int = 30) throws -> String {
        let path = NSTemporaryDirectory() + "hanging-tool-\(UUID().uuidString).sh"
        let script = """
        #!/bin/sh
        case "$1" in
          \(command)) sleep \(sleepSeconds); exit 0 ;;
          *) exit 0 ;;
        esac
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func test_validate_timesOutRatherThanHangingForever() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 0, "apply": 0, "remove": 0])
        let swift = try makeHangingTool(hangingOn: "build")
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let start = Date()
        do {
            _ = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory(), timeout: 0.3)
            XCTFail("expected validate() to throw sandboxTimedOut")
        } catch TriageError.sandboxTimedOut(let command, let seconds) {
            XCTAssertTrue(command.contains("build"))
            XCTAssertEqual(seconds, 0.3)
        }
        // The fake tool sleeps 30s; a passing elapsed-time assertion well
        // under that proves the hung process was actually killed, not just
        // that the error type happened to match.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func test_validate_doesNotTimeOutWhenWithinBudget() async throws {
        let git = try makeFakeTool(exitCodes: ["worktree": 0, "apply": 0, "remove": 0])
        let swift = try makeFakeTool(exitCodes: ["build": 0, "test": 0])
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let result = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory(), timeout: 30)

        XCTAssertTrue(result.passed)
    }

    // Distinguishes `git worktree add` from `git worktree remove` (both start
    // with $1=="worktree", which makeFakeTool's single-arg dispatch can't
    // tell apart), and makes the remove case slow on purpose.
    private func makeGitToolWithSlowWorktreeRemove(removeDelaySeconds: Double) throws -> String {
        let path = NSTemporaryDirectory() + "slow-remove-git-\(UUID().uuidString).sh"
        let script = """
        #!/bin/sh
        if [ "$1" = "worktree" ] && [ "$2" = "remove" ]; then
          sleep \(removeDelaySeconds)
        fi
        exit 0
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    // Regression test: worktree cleanup used to be a fire-and-forget
    // `Task { ... }` inside a `defer`, never awaited. In a short-lived CLI
    // process, that detached task races against process exit and generally
    // loses — the worktree leaks on essentially every real `xctriage
    // remediate` invocation, contradicting the comment above the cleanup
    // that says "always release the worktree". If validate() properly
    // awaits cleanup, it can't return before the (deliberately slow) `git
    // worktree remove` finishes.
    func test_validate_awaitsWorktreeCleanupBeforeReturning() async throws {
        let removeDelay = 2.0
        let git = try makeGitToolWithSlowWorktreeRemove(removeDelaySeconds: removeDelay)
        let swift = try makeFakeTool(exitCodes: ["build": 0, "test": 0])
        let validator = SandboxValidator(gitPath: git, swiftPath: swift)

        let start = Date()
        _ = try await validator.validate(proposal: proposal(), repoRoot: NSTemporaryDirectory())
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, removeDelay, "validate() returned before worktree cleanup finished — cleanup is not being awaited")
    }
}

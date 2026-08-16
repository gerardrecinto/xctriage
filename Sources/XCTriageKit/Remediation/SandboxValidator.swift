import Foundation

// Same pipe-draining rationale as XCResultParser: readabilityHandler drains
// continuously so a chatty `swift build`/`swift test` can't fill the pipe's
// kernel buffer and deadlock the child against the parent's termination wait.
private final class ProcessOutputBuffer: @unchecked Sendable {
    var data = Data()
}

// Same rationale as ProcessOutputBuffer/DBHandle elsewhere in this codebase:
// Process isn't Sendable, so a cancellation handler that needs to terminate
// it goes through this wrapper instead of capturing the Process directly.
private final class SandboxProcessHandle: @unchecked Sendable {
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }
    func terminateIfRunning() {
        if process.isRunning { process.terminate() }
    }
}

// Isolated, disposable validation of a PatchProposal before it is ever shown
// to a human or turned into a PR. Never touches the caller's working tree:
// the diff is applied inside an ephemeral `git worktree`, built, and tested
// there, then the worktree is torn down whether validation passed or failed.
public actor SandboxValidator {

    public struct Result: Sendable, Equatable {
        public let applied: Bool
        public let buildSucceeded: Bool
        public let testSucceeded: Bool
        public let output: String

        public var passed: Bool { applied && buildSucceeded && testSucceeded }

        public init(applied: Bool, buildSucceeded: Bool, testSucceeded: Bool, output: String) {
            self.applied = applied
            self.buildSucceeded = buildSucceeded
            self.testSucceeded = testSucceeded
            self.output = output
        }
    }

    private let gitPath: String
    private let swiftPath: String

    public init(gitPath: String = "/usr/bin/git", swiftPath: String = "/usr/bin/swift") {
        self.gitPath = gitPath
        self.swiftPath = swiftPath
    }

    // repoRoot must be a git worktree/checkout; testFilter narrows `swift test`
    // to the originally failing test when known, so validation stays fast and
    // proves the specific regression is fixed rather than the whole suite.
    // timeout applies per shell-out (worktree add, apply, build, test), not
    // to validate() as a whole — see docs/runbooks/sandbox-hang.md, which
    // this parameter closes the gap described in.
    public func validate(
        proposal: PatchProposal,
        repoRoot: String,
        testFilter: String? = nil,
        timeout: TimeInterval = 300
    ) async throws -> Result {
        let sandboxDir = NSTemporaryDirectory() + "xctriage-sandbox-\(UUID().uuidString)"

        let (worktreeCode, worktreeOut) = try await run(
            gitPath, ["worktree", "add", "--detach", sandboxDir, "HEAD"], cwd: repoRoot, timeout: timeout
        )
        guard worktreeCode == 0 else {
            return Result(applied: false, buildSucceeded: false, testSucceeded: false, output: worktreeOut)
        }

        // Always release the worktree, even if a later step throws or the
        // diff/build/test fails partway through — a leaked worktree would
        // silently accumulate across every remediation attempt. This has to
        // be awaited, not fired-and-forgotten: xctriage is a short-lived CLI
        // process, so a detached cleanup Task races process exit and loses
        // almost every time — see the regression test for this in
        // SandboxValidatorTests.
        do {
            let result = try await runSteps(
                proposal: proposal, sandboxDir: sandboxDir, testFilter: testFilter, timeout: timeout
            )
            _ = try? await run(gitPath, ["worktree", "remove", "--force", sandboxDir], cwd: repoRoot, timeout: timeout)
            return result
        } catch {
            _ = try? await run(gitPath, ["worktree", "remove", "--force", sandboxDir], cwd: repoRoot, timeout: timeout)
            throw error
        }
    }

    private func runSteps(
        proposal: PatchProposal, sandboxDir: String, testFilter: String?, timeout: TimeInterval
    ) async throws -> Result {
        // Real `git worktree add` creates sandboxDir itself; harmless no-op
        // there. A stubbed git in tests doesn't, so this keeps the write below
        // from failing on a directory that only the real tool would produce.
        try? FileManager.default.createDirectory(atPath: sandboxDir, withIntermediateDirectories: true)

        let diffPath = sandboxDir + "/xctriage-proposal.diff"
        try proposal.unifiedDiff.write(toFile: diffPath, atomically: true, encoding: .utf8)

        let (applyCode, applyOut) = try await run(gitPath, ["apply", diffPath], cwd: sandboxDir, timeout: timeout)
        guard applyCode == 0 else {
            return Result(applied: false, buildSucceeded: false, testSucceeded: false, output: applyOut)
        }

        let (buildCode, buildOut) = try await run(swiftPath, ["build"], cwd: sandboxDir, timeout: timeout)
        guard buildCode == 0 else {
            return Result(applied: true, buildSucceeded: false, testSucceeded: false, output: buildOut)
        }

        var testArgs = ["test"]
        if let testFilter { testArgs += ["--filter", testFilter] }
        let (testCode, testOut) = try await run(swiftPath, testArgs, cwd: sandboxDir, timeout: timeout)

        return Result(applied: true, buildSucceeded: true, testSucceeded: testCode == 0, output: testOut)
    }

    // MARK: - Private

    private func run(_ executable: String, _ arguments: [String], cwd: String, timeout: TimeInterval) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let handle = SandboxProcessHandle(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        return try await withThrowingTaskGroup(of: (Int32, String).self) { group in
            group.addTask {
                try await self.runToCompletion(handle: handle)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                handle.terminateIfRunning()
                throw TriageError.sandboxTimedOut(
                    command: "\(executable) \(arguments.joined(separator: " "))", seconds: timeout
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TriageError.parseError("sandbox process produced no result")
            }
            return result
        }
    }

    // Isolated so the timeout race in run(_:_:cwd:timeout:) can cancel this
    // specific piece (which kills the process via SandboxProcessHandle)
    // without the cancellation handler having to live inline in a
    // withThrowingTaskGroup child closure.
    private func runToCompletion(handle: SandboxProcessHandle) async throws -> (Int32, String) {
        let process = handle.process
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let outHandle = handle.stdoutPipe.fileHandleForReading
                    let errHandle = handle.stderrPipe.fileHandleForReading
                    let bufferQueue = DispatchQueue(label: "xctriage.sandbox.output")
                    let stdoutBuffer = ProcessOutputBuffer()
                    let stderrBuffer = ProcessOutputBuffer()

                    outHandle.readabilityHandler = { fileHandle in
                        let chunk = fileHandle.availableData
                        guard !chunk.isEmpty else { return }
                        bufferQueue.sync { stdoutBuffer.data.append(chunk) }
                    }
                    errHandle.readabilityHandler = { fileHandle in
                        let chunk = fileHandle.availableData
                        guard !chunk.isEmpty else { return }
                        bufferQueue.sync { stderrBuffer.data.append(chunk) }
                    }

                    process.terminationHandler = { p in
                        let trailingOut = outHandle.readDataToEndOfFile()
                        let trailingErr = errHandle.readDataToEndOfFile()
                        outHandle.readabilityHandler = nil
                        errHandle.readabilityHandler = nil

                        let combined: String = bufferQueue.sync {
                            stdoutBuffer.data.append(trailingOut)
                            stderrBuffer.data.append(trailingErr)
                            let out = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                            let err = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                            return err.isEmpty ? out : out + "\n" + err
                        }
                        continuation.resume(returning: (p.terminationStatus, combined))
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            },
            onCancel: {
                handle.terminateIfRunning()
            }
        )
    }
}

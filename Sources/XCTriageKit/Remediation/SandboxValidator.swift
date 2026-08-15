import Foundation

// Same pipe-draining rationale as XCResultParser: readabilityHandler drains
// continuously so a chatty `swift build`/`swift test` can't fill the pipe's
// kernel buffer and deadlock the child against the parent's termination wait.
private final class ProcessOutputBuffer: @unchecked Sendable {
    var data = Data()
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
    public func validate(
        proposal: PatchProposal,
        repoRoot: String,
        testFilter: String? = nil
    ) async throws -> Result {
        let sandboxDir = NSTemporaryDirectory() + "xctriage-sandbox-\(UUID().uuidString)"

        let (worktreeCode, worktreeOut) = try await run(
            gitPath, ["worktree", "add", "--detach", sandboxDir, "HEAD"], cwd: repoRoot
        )
        guard worktreeCode == 0 else {
            return Result(applied: false, buildSucceeded: false, testSucceeded: false, output: worktreeOut)
        }

        // Always release the worktree, even if a later step throws or the
        // diff/build/test fails partway through — a leaked worktree would
        // silently accumulate across every remediation attempt.
        defer {
            Task { _ = try? await run(gitPath, ["worktree", "remove", "--force", sandboxDir], cwd: repoRoot) }
        }

        // Real `git worktree add` creates sandboxDir itself; harmless no-op
        // there. A stubbed git in tests doesn't, so this keeps the write below
        // from failing on a directory that only the real tool would produce.
        try? FileManager.default.createDirectory(atPath: sandboxDir, withIntermediateDirectories: true)

        let diffPath = sandboxDir + "/xctriage-proposal.diff"
        try proposal.unifiedDiff.write(toFile: diffPath, atomically: true, encoding: .utf8)

        let (applyCode, applyOut) = try await run(gitPath, ["apply", diffPath], cwd: sandboxDir)
        guard applyCode == 0 else {
            return Result(applied: false, buildSucceeded: false, testSucceeded: false, output: applyOut)
        }

        let (buildCode, buildOut) = try await run(swiftPath, ["build"], cwd: sandboxDir)
        guard buildCode == 0 else {
            return Result(applied: true, buildSucceeded: false, testSucceeded: false, output: buildOut)
        }

        var testArgs = ["test"]
        if let testFilter { testArgs += ["--filter", testFilter] }
        let (testCode, testOut) = try await run(swiftPath, testArgs, cwd: sandboxDir)

        return Result(applied: true, buildSucceeded: true, testSucceeded: testCode == 0, output: testOut)
    }

    // MARK: - Private

    private func run(_ executable: String, _ arguments: [String], cwd: String) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let outHandle = stdoutPipe.fileHandleForReading
            let errHandle = stderrPipe.fileHandleForReading
            let bufferQueue = DispatchQueue(label: "xctriage.sandbox.output")
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()

            outHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                bufferQueue.sync { stdoutBuffer.data.append(chunk) }
            }
            errHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
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
    }
}

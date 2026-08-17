import ArgumentParser
import XCTriageKit
import Foundation

@main
struct XCTriage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xctriage",
        abstract: "AI-powered CI failure analysis for Apple platforms",
        version: "1.4.0",
        subcommands: [Analyze.self, Flaky.self, Remediate.self]
    )
}

// MARK: analyze

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Triage a CI build log or xcresult bundle"
    )

    @Argument(help: "Build log path (- for stdin) or .xcresult bundle path")
    var input: String = "-"

    @Option(name: .shortAndLong, help: "CI source: xcodebuild | xcresult | github | generic")
    var source: String = "xcodebuild"

    @Option(name: .long, help: "Build ID for tracking")
    var buildID: String?

    @Flag(name: .long, help: "Use Claude when rule confidence < threshold (requires XCTRIAGE_ANTHROPIC_API_KEY)")
    var llm: Bool = false

    @Flag(name: .long, help: "Always use Claude regardless of rule confidence")
    var llmAlways: Bool = false

    @Option(name: .long, help: "Confidence threshold for LLM fallback (default: 0.60)")
    var llmThreshold: Double = 0.60

    @Option(name: .shortAndLong, help: "Output format: terminal | json | slack")
    var output: String = "terminal"

    @Option(name: .long, help: "Slack webhook URL (or set XCTRIAGE_SLACK_WEBHOOK)")
    var slackWebhook: String?

    @Flag(name: .long, help: "Skip recording failures in flaky test tracker")
    var noTrack: Bool = false

    @Option(name: .long, help: "Flaky test DB path")
    var db: String = "~/.xctriage/flaky.db"

    @Flag(name: .long, help: "Exit 1 when a failure is detected (CI gate mode)")
    var exitCode: Bool = false

    mutating func run() async throws {
        let t0 = Date()

        // Read log text
        let logText: String
        if input == "-" {
            logText = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } else if input.hasSuffix(".xcresult") {
            // xcresult mode: summary via xcresulttool then parse as text
            let parser = XCResultParser()
            let sites = try await parser.testFailures(bundlePath: input)
            let entries = sites.map { s in
                LogEntry(lineNumber: 0, level: .error,
                         message: "\(s.locationDescription): \(s.errorMessage)", raw: "")
            }
            var result = RuleClassifier().classify(entries)

            // Same --llm/--llm-always fallback the build-log path applies
            // below — previously missing here entirely, so those flags were
            // silently ignored for .xcresult input.
            let apiKey = ProcessInfo.processInfo.environment["XCTRIAGE_ANTHROPIC_API_KEY"] ?? ""
            if LLMFallbackPolicy.shouldUseLLM(
                hasAPIKey: !apiKey.isEmpty, llmAlways: llmAlways, llmRequested: llm,
                confidence: result.confidence, threshold: llmThreshold
            ) {
                result = try await ClaudeClassifier(apiKey: apiKey).classify(entries)
            }
            if result.failureSites.isEmpty {
                result.failureSites = sites
            }

            let duration = Date().timeIntervalSince(t0) * 1000
            let report = TriageReport(
                buildID: buildID,
                source: .xcresult,
                classification: result,
                rawLogLines: entries.count,
                durationMS: duration
            )
            try await emitReport(report)
            if exitCode && !result.failureSites.isEmpty {
                Foundation.exit(1)
            }
            return
        } else {
            guard let text = try? String(contentsOfFile: input, encoding: .utf8) else {
                throw TriageError.fileNotFound(input)
            }
            logText = text
        }

        let ciSource = CISource(rawValue: source == "github" ? "github_actions" : source) ?? .xcodebuild
        let parser = BuildLogParser()
        let entries = parser.parse(logText)
        let context = parser.extractFailureContext(entries)

        var result = RuleClassifier().classify(context)

        // LLM fallback — same LLMFallbackPolicy.shouldUseLLM the .xcresult branch above uses.
        let apiKey = ProcessInfo.processInfo.environment["XCTRIAGE_ANTHROPIC_API_KEY"] ?? ""
        if LLMFallbackPolicy.shouldUseLLM(
            hasAPIKey: !apiKey.isEmpty, llmAlways: llmAlways, llmRequested: llm,
            confidence: result.confidence, threshold: llmThreshold
        ) {
            let classifier = ClaudeClassifier(apiKey: apiKey)
            result = try await classifier.classify(context)
        }

        // Merge failure sites from parser if classifier has none
        if result.failureSites.isEmpty {
            result.failureSites = parser.extractFailureSites(context)
        }

        let duration = Date().timeIntervalSince(t0) * 1000

        // Flaky tracking
        var flakyScores: [String: Double] = [:]
        let testNames = result.failureSites.compactMap(\.testName)
        if !testNames.isEmpty, let tracker = try? FlakyTestTracker(dbPath: db) {
            flakyScores = (try? await tracker.scores(for: testNames)) ?? [:]
            if !noTrack {
                for name in testNames {
                    try? await tracker.record(testName: name, buildID: buildID, source: ciSource.rawValue)
                }
            }
        }

        let report = TriageReport(
            buildID: buildID,
            source: ciSource,
            classification: result,
            flakyTestScores: flakyScores,
            rawLogLines: entries.count,
            durationMS: duration
        )
        try await emitReport(report)

        if exitCode && !result.failureSites.isEmpty {
            Foundation.exit(1)
        }
    }

    private func emitReport(_ report: TriageReport) async throws {
        switch output {
        case "json":
            try JSONReporter().report(report)
        case "slack":
            let urlStr = slackWebhook ?? ProcessInfo.processInfo.environment["XCTRIAGE_SLACK_WEBHOOK"] ?? ""
            guard let url = URL(string: urlStr), !urlStr.isEmpty else {
                throw TriageError.parseError("--slack-webhook or XCTRIAGE_SLACK_WEBHOOK required")
            }
            TerminalReporter().report(report)
            // Post synchronously so the process can't exit (--exit-code, or just
            // reaching the end of run()) before the webhook request lands.
            try await SlackReporter(webhookURL: url).report(report)
        default:
            TerminalReporter().report(report)
        }
    }
}

// MARK: remediate

struct Remediate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Propose a minimal-diff fix for a classified failure (policy-gated, never auto-applied)"
    )

    @Argument(help: "Build log path (- for stdin) or .xcresult bundle path")
    var input: String = "-"

    @Option(name: .shortAndLong, help: "CI source: xcodebuild | xcresult | github | generic")
    var source: String = "xcodebuild"

    @Option(name: .long, help: "Root directory failing file paths are relative to")
    var repoRoot: String = "."

    @Option(name: .long, help: "Remediation attempt number, checked against the policy's max-attempts gate")
    var attempt: Int = 1

    @Option(name: .long, help: "Write the proposed unified diff to this path instead of stdout")
    var out: String?

    @Flag(name: .long, help: "Skip sandbox build/test validation (faster, but the proposal is unverified)")
    var skipSandbox: Bool = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Open a draft PR (via gh CLI) once policy allows the patch and sandbox validation passes. "
                + "Never merges; requires --skip-sandbox to be unset."
        )
    )
    var createPR: Bool = false

    @Option(name: .long, help: "Base branch to open the draft PR against (used with --create-pr)")
    var baseBranch: String = "main"

    @Option(name: .long, help: "Durable remediation state machine DB path")
    var stateDB: String = "~/.xctriage/remediation_state.db"

    @Option(name: .long, help: "Idempotency store DB path (dedups retried --create-pr triggers)")
    var idempotencyDB: String = "~/.xctriage/idempotency.db"

    @Option(name: .long, help: "Seconds to allow each sandbox step (worktree/apply/build/test) before killing it and failing validation")
    var sandboxTimeout: Double = 300

    mutating func run() async throws {
        let apiKey = ProcessInfo.processInfo.environment["XCTRIAGE_ANTHROPIC_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            throw TriageError.missingAPIKey
        }

        let (failureSites, category, confidence) = try await Self.classifyFailure(input: input)

        guard let site = failureSites.first else {
            print("No failure sites found; nothing to remediate.")
            return
        }

        let fingerprint = FailureFingerprint(category: category, failureSites: failureSites)
        let policy = RemediationPolicy()
        let stateMachine = try RemediationStateMachine(dbPath: stateDB)
        let idempotency = try IdempotencyStore(dbPath: idempotencyDB)

        // Dedup first, before spending any LLM tokens or sandbox time: if a
        // prior run (or a retried CI trigger for the same failure) already
        // opened a PR for this fingerprint, reuse that result instead of
        // generating and validating a second patch for a PR that already
        // exists. See docs/architecture PART_B section 43.
        if createPR, let existingPR = try await idempotency.existingResult(operation: "create_pr", key: fingerprint.value) {
            print("PR already opened for fingerprint [\(fingerprint.value)]: \(existingPR)")
            return
        }

        let eligibility = policy.isEligibleForRemediation(category: category, confidence: confidence, attemptNumber: attempt)
        guard case .allowed = eligibility else {
            if case .denied(let reason) = eligibility {
                print("Remediation blocked [\(fingerprint.value)]: \(reason)")
            }
            try await stateMachine.transition(key: fingerprint.value, to: .policyRejected)
            Foundation.exit(4)
        }

        guard let file = site.file else {
            print("Remediation blocked [\(fingerprint.value)]: failure site has no associated file")
            Foundation.exit(4)
        }

        let filePath = FailureSitePathResolver.resolve(file: file, repoRoot: repoRoot)
        guard let fileContents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            throw TriageError.fileNotFound(filePath)
        }

        // PatchGenerator must never be shown the absolute resolved path: an
        // LLM asked to produce a diff for a file it was shown at an
        // absolute path plausibly mirrors that same absolute path into the
        // diff's headers, and `git apply` rejects an absolute path there
        // outright (verified empirically — "error: invalid path", exit
        // 128). Show it a clean repo-relative path instead.
        let relativeFile = FailureSitePathResolver.repoRelativePath(forResolvedFile: filePath, repoRoot: repoRoot)
        let relativeSite = FailureSite(
            file: relativeFile, line: site.line, column: site.column,
            testName: site.testName, errorMessage: site.errorMessage
        )

        let generator = PatchGenerator(apiKey: apiKey)
        let proposal = try await generator.proposePatch(category: category, failureSite: relativeSite, fileContents: fileContents)
        try await stateMachine.transition(key: fingerprint.value, to: .patchProposed)

        let patchDecision = policy.isPatchAllowed(filesChanged: [proposal.filePath])
        guard case .allowed = patchDecision else {
            if case .denied(let reason) = patchDecision {
                print("Patch blocked [\(fingerprint.value)]: \(reason)")
            }
            try await stateMachine.transition(key: fingerprint.value, to: .policyRejected)
            Foundation.exit(4)
        }

        // RemediationPolicy above only validated proposal.filePath, the
        // LLM's own claim of what it changed — it never checked that the
        // diff actually targets that same file. Without this, a response
        // where those two disagree would sail past the forbidden-path
        // check entirely.
        guard UnifiedDiffInspector.matchesClaimedPath(proposal.filePath, diff: proposal.unifiedDiff) else {
            print("Patch blocked [\(fingerprint.value)]: diff does not target the claimed file_path (\(proposal.filePath))")
            try await stateMachine.transition(key: fingerprint.value, to: .policyRejected)
            Foundation.exit(4)
        }

        if createPR && skipSandbox {
            print("Refusing --create-pr with --skip-sandbox: a PR must be backed by a passing sandbox validation.")
            Foundation.exit(4)
        }

        let (sandboxLine, sandboxResult) = try await Self.runSandboxIfNeeded(
            skipSandbox: skipSandbox,
            proposal: proposal,
            repoRoot: repoRoot,
            testFilter: site.testName,
            timeout: sandboxTimeout,
            fingerprint: fingerprint,
            stateMachine: stateMachine
        )

        let header = """
        Fingerprint: \(fingerprint.value)
        Category:    \(category.displayName)
        Confidence:  \(String(format: "%.2f", proposal.confidence))
        \(sandboxLine)
        Rationale:   \(proposal.rationale)

        """

        if let out {
            try (header + proposal.unifiedDiff + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            print("Wrote proposal to \(out)")
        } else {
            print(header + proposal.unifiedDiff)
        }

        // Reaching here means policy allowed the patch and (unless
        // --skip-sandbox, which --create-pr refuses above) sandbox
        // validation passed. This only ever opens a draft PR — see
        // GitHubPRWriter: no merge path exists in this tool.
        try await Self.openDraftPRIfRequested(
            createPR: createPR,
            context: RemediationContext(proposal: proposal, fingerprint: fingerprint, category: category, failureSite: site),
            sandboxResult: sandboxResult,
            repoRoot: repoRoot,
            baseBranch: baseBranch,
            stateMachine: stateMachine,
            idempotency: idempotency
        )
    }

    // MARK: - Helpers (kept out of run() to stay under swiftlint's function_body_length/cyclomatic_complexity limits)

    private static func classifyFailure(
        input: String
    ) async throws -> (failureSites: [FailureSite], category: FailureCategory, confidence: Double) {
        if input.hasSuffix(".xcresult") {
            let parser = XCResultParser()
            let sites = try await parser.testFailures(bundlePath: input)
            let entries = sites.map { s in
                LogEntry(lineNumber: 0, level: .error,
                         message: "\(s.locationDescription): \(s.errorMessage)", raw: "")
            }
            let result = RuleClassifier().classify(entries)
            return (sites, result.category, result.confidence)
        }

        let logText: String
        if input == "-" {
            logText = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } else {
            guard let text = try? String(contentsOfFile: input, encoding: .utf8) else {
                throw TriageError.fileNotFound(input)
            }
            logText = text
        }
        let parser = BuildLogParser()
        let entries = parser.parse(logText)
        let context = parser.extractFailureContext(entries)
        let result = RuleClassifier().classify(context)
        let sites = result.failureSites.isEmpty ? parser.extractFailureSites(context) : result.failureSites
        return (sites, result.category, result.confidence)
    }

    private static func runSandboxIfNeeded(
        skipSandbox: Bool,
        proposal: PatchProposal,
        repoRoot: String,
        testFilter: String?,
        timeout: Double,
        fingerprint: FailureFingerprint,
        stateMachine: RemediationStateMachine
    ) async throws -> (sandboxLine: String, result: SandboxValidator.Result?) {
        guard !skipSandbox else {
            return ("Sandbox:     skipped (--skip-sandbox)", nil)
        }

        try await stateMachine.transition(key: fingerprint.value, to: .validating)
        let result = try await SandboxValidator().validate(
            proposal: proposal,
            repoRoot: repoRoot,
            testFilter: testFilter,
            timeout: timeout
        )
        guard result.passed else {
            print("Sandbox rejected [\(fingerprint.value)]: applied=\(result.applied) build=\(result.buildSucceeded) test=\(result.testSucceeded)")
            print(result.output)
            try await stateMachine.transition(key: fingerprint.value, to: .sandboxFailed)
            Foundation.exit(4)
        }
        try await stateMachine.transition(key: fingerprint.value, to: .sandboxPassed)
        return ("Sandbox:     build passed, target test passed", result)
    }

    // Bundles the pieces GitHubPRWriter needs so openDraftPRIfRequested stays
    // under swiftlint's function_parameter_count error threshold.
    private struct RemediationContext {
        let proposal: PatchProposal
        let fingerprint: FailureFingerprint
        let category: FailureCategory
        let failureSite: FailureSite
    }

    private static func openDraftPRIfRequested(
        createPR: Bool,
        context: RemediationContext,
        sandboxResult: SandboxValidator.Result?,
        repoRoot: String,
        baseBranch: String,
        stateMachine: RemediationStateMachine,
        idempotency: IdempotencyStore
    ) async throws {
        guard createPR, let sandboxResult else { return }

        let writer = GitHubPRWriter()
        do {
            let prResult = try await writer.createDraftPR(
                proposal: context.proposal,
                fingerprint: context.fingerprint,
                category: context.category,
                failureSite: context.failureSite,
                sandboxResult: sandboxResult,
                repoRoot: repoRoot,
                baseBranch: baseBranch
            )
            let resultDescription = prResult.prURL ?? "(no URL returned by gh) branch=\(prResult.branchName)"
            try await idempotency.recordProcessed(operation: "create_pr", key: context.fingerprint.value, result: resultDescription)
            try await stateMachine.transition(key: context.fingerprint.value, to: .prOpened)
            print("Opened draft PR on branch \(prResult.branchName): \(prResult.prURL ?? "(no URL returned by gh)")")
        } catch {
            try await stateMachine.transition(key: context.fingerprint.value, to: .prFailed)
            throw error
        }
    }
}

// MARK: flaky

struct Flaky: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show top flaky tests from the 90-day tracker"
    )

    @Option(name: .shortAndLong, help: "Number of results")
    var n: Int = 20

    @Option(name: .long, help: "Flaky test DB path")
    var db: String = "~/.xctriage/flaky.db"

    @Flag(name: .long, help: "Also list tests over the quarantine score threshold, separately from the top-N list")
    var showQuarantineCandidates: Bool = false

    @Option(name: .long, help: "Score threshold (exclusive) for --show-quarantine-candidates")
    var quarantineThreshold: Double = 0.70

    mutating func run() async throws {
        let tracker = try FlakyTestTracker(dbPath: db)
        let top = try await tracker.topFlaky(n: n)
        if top.isEmpty {
            print("No flaky test history.")
            return
        }
        print("\n  Top \(top.count) flaky tests (last 90 days)\n")
        print("  Score   Test")
        print("  " + String(repeating: "-", count: 55))
        for (name, score) in top {
            print("  \(FlakyBarFormatter.row(name: name, score: score))")
        }
        print()

        if showQuarantineCandidates {
            let candidates = try await tracker.quarantineCandidates(threshold: quarantineThreshold)
            if candidates.isEmpty {
                print("  No tests above the \(String(format: "%.2f", quarantineThreshold)) quarantine threshold.\n")
            } else {
                print("  Quarantine candidates (score > \(String(format: "%.2f", quarantineThreshold)))\n")
                for (name, score) in candidates {
                    print("  \(FlakyBarFormatter.row(name: name, score: score))")
                }
                print()
            }
        }
    }
}

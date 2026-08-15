import ArgumentParser
import XCTriageKit
import Foundation

@main
struct XCTriage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xctriage",
        abstract: "AI-powered CI failure analysis for Apple platforms",
        version: "1.3.0",
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
            let result = RuleClassifier().classify(entries)
            let duration = Date().timeIntervalSince(t0) * 1000
            let report = TriageReport(
                buildID: buildID,
                source: .xcresult,
                classification: ClassificationResult(
                    category: result.category,
                    confidence: result.confidence,
                    failureSites: sites,
                    summary: result.summary,
                    suggestedFix: result.suggestedFix
                ),
                rawLogLines: entries.count,
                durationMS: duration
            )
            try await emitReport(report)
            if exitCode && !sites.isEmpty {
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

        // LLM fallback
        let apiKey = ProcessInfo.processInfo.environment["XCTRIAGE_ANTHROPIC_API_KEY"] ?? ""
        if !apiKey.isEmpty && (llmAlways || (llm && result.confidence < llmThreshold)) {
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

    mutating func run() async throws {
        let apiKey = ProcessInfo.processInfo.environment["XCTRIAGE_ANTHROPIC_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            throw TriageError.missingAPIKey
        }

        let failureSites: [FailureSite]
        let category: FailureCategory
        let confidence: Double

        if input.hasSuffix(".xcresult") {
            let parser = XCResultParser()
            let sites = try await parser.testFailures(bundlePath: input)
            let entries = sites.map { s in
                LogEntry(lineNumber: 0, level: .error,
                         message: "\(s.locationDescription): \(s.errorMessage)", raw: "")
            }
            let result = RuleClassifier().classify(entries)
            failureSites = sites
            category = result.category
            confidence = result.confidence
        } else {
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
            failureSites = result.failureSites.isEmpty ? parser.extractFailureSites(context) : result.failureSites
            category = result.category
            confidence = result.confidence
        }

        guard let site = failureSites.first else {
            print("No failure sites found; nothing to remediate.")
            return
        }

        let fingerprint = FailureFingerprint(category: category, failureSites: failureSites)
        let policy = RemediationPolicy()

        let eligibility = policy.isEligibleForRemediation(category: category, confidence: confidence, attemptNumber: attempt)
        guard case .allowed = eligibility else {
            if case .denied(let reason) = eligibility {
                print("Remediation blocked [\(fingerprint.value)]: \(reason)")
            }
            Foundation.exit(4)
        }

        guard let file = site.file else {
            print("Remediation blocked [\(fingerprint.value)]: failure site has no associated file")
            Foundation.exit(4)
        }

        let filePath = (repoRoot as NSString).appendingPathComponent(file)
        guard let fileContents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            throw TriageError.fileNotFound(filePath)
        }

        let generator = PatchGenerator(apiKey: apiKey)
        let proposal = try await generator.proposePatch(category: category, failureSite: site, fileContents: fileContents)

        let patchDecision = policy.isPatchAllowed(filesChanged: [proposal.filePath])
        guard case .allowed = patchDecision else {
            if case .denied(let reason) = patchDecision {
                print("Patch blocked [\(fingerprint.value)]: \(reason)")
            }
            Foundation.exit(4)
        }

        var sandboxLine = "Sandbox:     skipped (--skip-sandbox)"
        if !skipSandbox {
            let sandboxResult = try await SandboxValidator().validate(
                proposal: proposal,
                repoRoot: repoRoot,
                testFilter: site.testName
            )
            guard sandboxResult.passed else {
                print("Sandbox rejected [\(fingerprint.value)]: applied=\(sandboxResult.applied) build=\(sandboxResult.buildSucceeded) test=\(sandboxResult.testSucceeded)")
                print(sandboxResult.output)
                Foundation.exit(4)
            }
            sandboxLine = "Sandbox:     build passed, target test passed"
        }

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
    }
}

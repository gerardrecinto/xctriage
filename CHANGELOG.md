# Changelog

## Unreleased

### Added
- `xctriage analyze --output sarif`: SARIF 2.1.0 output (`SARIFReporter`), one result per `FailureSite` with a stable `ruleId` derived from `FailureCategory`, a `level` derived from category + classifier confidence, and a `partialFingerprints` entry reusing the existing `FailureFingerprint` type so the same failure fingerprints identically across reruns. `locations` (`physicalLocation`/`region`) are only emitted when a real file/line is known; never fabricated.
- `xctriage analyze --output github`: GitHub Actions workflow-command annotations (`GitHubReporter`) — `::error file=...,line=...,col=...::message` / `::warning ...::`, one line per `FailureSite`, with GitHub's documented `%`/`\r`/`\n`/`:`/`,` escaping applied. Pure formatting over the existing `TriageReport`; no network access, no LLM.
- `AnnotationMapping`: shared `FailureCategory` → ruleId/severity mapping used by both new reporters, so SARIF and GitHub annotations agree on what counts as an error vs. a warning for a given category.

## v1.4.1

### Fixed
- **`xctriage remediate` couldn't actually read the failing file for any real compiler-reported failure.** Real `xcodebuild`/`swift build` diagnostics report absolute file paths (verified against real `swift build` output, not assumed). The code joined that path onto `repoRoot` with `NSString.appendingPathComponent`, which doesn't special-case an absolute argument — `"." + "/Users/x/Foo.swift"` produced the nonsensical `"./Users/x/Foo.swift"`, which doesn't exist. Reproduced end-to-end against the real binary and a real compile error before fixing it (`Error: fileNotFound(...)`); this meant the entire policy → patch → sandbox → PR pipeline was unreachable for real usage. Fixed with `FailureSitePathResolver.resolve(file:repoRoot:)`.
- `PatchGenerator` was shown the absolute resolved file path with no instruction about path format, and an LLM asked to produce a diff for a file it was shown at an absolute path plausibly mirrors that same absolute path into the diff's `--- a/...`/`+++ b/...` headers — but `git apply` rejects an absolute path in a diff header outright (verified empirically: "error: invalid path", exit 128). Fixed with `FailureSitePathResolver.repoRelativePath(forResolvedFile:repoRoot:)`, so the LLM never sees an absolute path to begin with.
- Nothing verified that a `PatchProposal`'s claimed `file_path` matched the file its own `unified_diff` actually targets. Added `UnifiedDiffInspector.matchesClaimedPath`, wired as a new deterministic gate in `xctriage remediate` right after the existing forbidden-path check.
- That new check itself had a gap: it only inspected the diff's *first* `+++` header. Verified empirically that a single `unified_diff` string can contain multiple file header blocks concatenated together, and `git apply` applies all of them with no complaint — so a diff claiming to touch only an allowed file could have smuggled in hunks for a forbidden one (e.g. `RemediationPolicy.swift` itself). Fixed by requiring the diff touch *exactly* the one claimed file.
- `RemediationPolicy`'s forbidden-path safety check was case-sensitive, but macOS's default filesystem (APFS) is case-insensitive-but-preserving and `PatchProposal.filePath` is LLM-echoed, not guaranteed to preserve on-disk casing — `"sources/xctriage/main.swift"` bypassed a check that `"Sources/xctriage/main.swift"` would have caught. Fixed with a case-insensitive comparison.
- `SandboxValidator`'s worktree cleanup was a fire-and-forget `Task { ... }` inside a `defer`, never awaited. In a short-lived CLI process, that detached task races process exit and loses almost every time — sandbox worktrees leaked on essentially every real `xctriage remediate` invocation. Fixed by awaiting cleanup on both the success and thrown-error paths before returning.
- `TerminalReporter.confidenceBar` used `String(repeating:count:)` on an unclamped confidence value. `ClaudeClassifier` parses `confidence` straight out of untrusted LLM JSON with no bounds check, so an out-of-range value (e.g. `1.5` or `-0.3`) triggered a fatal trap ("Negative count not allowed"). Fixed by clamping, matching `FlakyBarFormatter`'s existing clamp.
- `SlackReporter` had no cap on mrkdwn text block length. Slack rejects an entire message if any single block exceeds 3000 characters, so an unusually long LLM-generated summary or fix made the whole notification silently fail to send instead of just being long. Added truncation.
- `BuildLogParser.extractFailureSites` deduped repeated Swift/ObjC compiler errors by file:line, but not repeated linker error lines — a duplicated `ld:` line (e.g. from double-logged CI output) produced duplicate `FailureSite`s.
- `Analyze.run()`'s `.xcresult` input path never checked `--llm`/`--llm-always` at all, unlike the build-log path a few lines below it — both flags were silently ignored for `.xcresult` input. Extracted the shared decision into `LLMFallbackPolicy.shouldUseLLM(...)` and wired both paths through it identically.
- `RemediationPolicy`'s forbidden-path list now also covers its own remediation pipeline (`Sources/XCTriageKit/Remediation/`) and the CLI entrypoint (`Sources/xctriage/`), closing a gap where a `compilation_error` in the tool's own safety machinery could have produced a PR patching that machinery.

### Added
- `FlakyTestTracker.quarantineCandidates(threshold:)`, wired into `xctriage flaky --show-quarantine-candidates` — the quarantine threshold the tracker's own header comment had documented since it was written, now actually computed.
- `SandboxValidator` now takes a `timeout` (CLI: `--sandbox-timeout`, default 300s per step) and kills a hung `swift build`/`swift test` instead of hanging the CLI forever.
- Test coverage for `FailureFingerprint`'s digit-run and full-path normalization behavior, previously implemented but untested directly.
- `docs/adr/` (8 ADRs), `docs/runbooks/` (5 runbooks), `docs/assets/` (3 SVG diagrams), `docs/architecture/WHAT_I_DID_NOT_BUILD.md`, `docs/architecture/HIGH_LEVEL_ARCHITECTURE.md`.
- A Jenkinsfile comment documenting why Jenkins archives the remediation diff instead of using `--create-pr` (no GitHub push credential configured for that pipeline — a real infrastructure gap, not something to fake).

### Changed
- Switched all documentation and code comments to first person — this project has one author, not a team.

## v1.4.0

### Added
- New `xctriage remediate` subcommand: fingerprint a failure, run it through a deterministic two-gate policy check (`RemediationPolicy`), generate a single-file patch with Claude (`PatchGenerator`), validate it in a disposable git worktree with a real `swift build` + `swift test` (`SandboxValidator`), and optionally open a draft PR (`GitHubPRWriter`, `--create-pr`, never merges). Wired into both CI systems for `compilation_error` failures.
- `RemediationStateMachine`: durable, SQLite-backed state machine for remediation attempts, keyed by failure fingerprint. Every transition is a persisted row; illegal jumps throw; a crashed process recovers from the last known state instead of repeating or losing work.
- `IdempotencyStore`: SQLite-backed dedup for retried `--create-pr` triggers. A repeated invocation for the same fingerprint reuses the recorded PR result instead of opening a duplicate.
- `SandboxValidator` now takes a `timeout` (CLI: `--sandbox-timeout`, default 300s per step) and actually kills a hung `swift build`/`swift test` instead of hanging the CLI forever.
- `FlakyTestTracker.quarantineCandidates(threshold:)`, wired into `xctriage flaky --show-quarantine-candidates` — the quarantine threshold the tracker's own header comment had documented since it was written, now actually computed.
- `RemediationPolicy`'s forbidden-path list now also covers its own remediation pipeline (`Sources/XCTriageKit/Remediation/`) and the CLI entrypoint (`Sources/xctriage/`), closing a gap where a `compilation_error` in the tool's own safety machinery could have produced a PR patching that machinery.
- `docs/adr/`: 8 Architecture Decision Records for the real, already-built parts of the system, each with alternatives considered and why they were rejected.
- `docs/runbooks/`: 5 operational runbooks for real failure modes (GitHub rate limits, LLM provider outages, duplicate PRs, sandbox hangs, SQLite lock contention).
- `docs/assets/`: 3 SVG diagrams (remediation state machine, CI pipeline, trust boundaries) drawn from the actual code.
- `docs/architecture/WHAT_I_DID_NOT_BUILD.md` and `docs/architecture/HIGH_LEVEL_ARCHITECTURE.md`: what's explicitly out of scope and why, and one high-level diagram covering the real CI flow plus the target CD flow.

### Fixed
- `Remediate.run()` had grown past SwiftLint's `function_body_length`/`function_parameter_count` error thresholds after the state-machine/idempotency wiring, breaking CI. Split into `classifyFailure`, `runSandboxIfNeeded`, and `openDraftPRIfRequested`.

## v1.3.0

### Added
- Sonnet 5 support: `ClaudeClassifier` now defaults to `claude-sonnet-5` (was `claude-sonnet-4-6`).
- Bounded LLM auto-remediation stage in Jenkins. On a test failure, `xctriage --llm` classifies the failure; only a high-confidence (>=0.75) `flaky_test` verdict gets an automatic one-time retry. Every other category posts the LLM's suggested fix to Slack and leaves the build failed for a human. The LLM picks the category, never the action.

### Changed
- README Claude badge updated to Sonnet 5.

## v1.2.0

### Fixed
- `XCResultParser` failed to extract file/line/column for every failure site: it parsed the URL's query string, but xcresulttool's `DocumentLocation` URLs encode `StartingLineNumber`/`StartingColumnNumber` in the fragment (`file:///path#StartingLineNumber=10&...`), not the query. Failure sites from `.xcresult` bundles were silently coming back with no location.
- `XCResultParser` could deadlock on large `.xcresult` bundles: it read stdout only after the `xcresulttool` process exited, which blocks forever once output exceeds the pipe's kernel buffer (64KB) because the child blocks writing to a full pipe while the parent waits for a termination that can't happen. Now drains both pipes continuously via `readabilityHandler`.
- `SlackReporter` threw `TriageError.claudeAPIError(0, ...)` on a failed webhook POST: wrong error case, and a hardcoded `0` that discarded the real HTTP status. Added `TriageError.slackWebhookFailed(Int, String)` and surfaced the actual status code.
- `xctriage flaky` built each row by interpolating the raw test name into a `String(format:)` template. A test name containing `%` (parameterized/perf test names do this) would be reinterpreted as a format specifier instead of literal text. Extracted `FlakyBarFormatter` so score formatting and the test name are never combined into one format string.
- `TerminalReporter` hardcoded `"Claude xcodebuild"` in the analysis-method line regardless of the report's actual source, so triaging a GitHub Actions or xcresult build under `--llm` always mislabeled itself as xcodebuild.

### Added
- Unit tests for `FlakyTestTracker`, `TerminalReporter`, `JSONReporter`, `SlackReporter`, `XCResultParser`, and `FlakyBarFormatter`, previously untested (22 to 47 tests).
- Trivy dependency/secret/misconfig scanning in both CI systems (GitHub Actions job uploads SARIF to Code Scanning; Jenkins stage archives JSON).
- Semgrep SAST stage in Jenkins, alongside GitHub Actions' existing CodeQL: CodeQL isn't practical to self-host in Jenkins without a GHAS license, so the two CI systems use different SAST tooling for the same purpose.
- `Lint` stage in Jenkins (SwiftLint), matching what GitHub Actions already ran.

### Changed
- `JSONReporter` and `TerminalReporter` now take an injectable `write` closure (defaulting to `print`) instead of calling `print` directly, so output is testable without OS-level stdout redirection.
- `SlackReporter` now takes an injectable `URLSession` (defaulting to `.shared`), matching the pattern `ClaudeClassifier` already used.

## v1.1.0
- Bump CLI version string to match the `v1.0.0` tag (was still printing `0.1.0`).
- Add SwiftLint and CodeQL to CI.
- Drop a stale `docs/architecture.drawio` link.
- Throw on Claude request encode failure instead of sending an empty body.
- First test coverage for `ClaudeClassifier`.
- Fix Slack post getting dropped on `--exit-code` runs.

## v1.0.0
- Initial release: rule-based + Claude-fallback CI failure triage for Jenkins, GitHub Actions, and xcodebuild; SQLite-backed flaky test tracker.

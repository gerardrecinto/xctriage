# Changelog

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

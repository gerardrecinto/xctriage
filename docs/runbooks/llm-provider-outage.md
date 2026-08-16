# Runbook: Anthropic API unavailable

## What happened?

Two types in this codebase call the Anthropic API directly over
`URLSession`: `ClaudeClassifier` (used only when `--llm` is passed to
classification, as a fallback when the deterministic `RuleClassifier` has
low confidence) and `PatchGenerator` (used by `xctriage remediate` to
propose a diff). If `api.anthropic.com` is down, rate-limited, or the
`XCTRIAGE_ANTHROPIC_API_KEY` is invalid, these calls fail.

## How do I know?

`Remediate.run()` checks for the API key up front and throws
`TriageError.missingAPIKey` immediately if it's empty — that's a
config error, not an outage. An actual outage or timeout surfaces as
whatever error `URLSession` throws (e.g. a `URLError` for a timeout or
connection failure) or, for a non-2xx HTTP response, however
`PatchGenerator`/`ClaudeClassifier` model that in their own decode logic.
Either way, it propagates up through `Remediate.run()` uncaught, and the
CLI exits non-zero with a Swift error description.

## What is the blast radius?

Only the parts of the pipeline that need the LLM. Deterministic
parsing/classification/fingerprinting (`BuildLogParser`, `XCResultParser`,
`RuleClassifier`, `FailureFingerprint`) do not call any network API and
keep working even if `api.anthropic.com` is completely unreachable —
this is the guarantee `docs/architecture/PART_B` section 56 states as a
design principle ("AI being unavailable must never prevent deterministic
CI/test analysis"), and it holds here because those types simply don't
import anything network-related.

`xctriage remediate` (patch generation) and `--llm`-flagged classification
are unavailable until the API is reachable again. Plain `xctriage analyze`
(no remediation, no `--llm`) is unaffected.

## What should happen automatically?

Nothing today — there is no retry/backoff wrapper around the
`URLSession` calls in `ClaudeClassifier` or `PatchGenerator`. A single
failed request is a single failed CLI invocation.

## What must a human do?

For CI: let the run fail and rely on `RuleClassifier`'s deterministic
output (already printed before any LLM call happens, for `xctriage
analyze`) to see what actually failed. For `xctriage remediate`
specifically: wait for the outage to clear and re-run; per the
idempotency runbook, a failed attempt before a PR is recorded is a safe,
non-duplicating retry.

## How do I verify recovery?

`curl -s https://api.anthropic.com` reachability (or just re-running
`xctriage remediate` with a known-good fixture) confirms the API is back.
There's no built-in health check command in this CLI today.

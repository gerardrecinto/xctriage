# Runbook: `swift build`/`swift test` hangs inside sandbox validation

## What happened?

`SandboxValidator.validate` shells out to `swift build` and `swift test`
inside a disposable git worktree (ADR-004). Like any child process
invocation, it can hang: a deadlocked test, a network call inside a test
that never times out, or (per the pipe-draining comment at the top of
`SandboxValidator.swift`) a chatty process filling a pipe buffer if the
draining logic itself has a bug.

## How do I know?

`xctriage remediate ... ` (with sandbox validation enabled, i.e. no
`--skip-sandbox`) simply never returns. There is no timeout wrapped around
`SandboxValidator.validate`'s `run(...)` calls today — this is a real,
current gap, not a hypothetical one.

## What is the blast radius?

One stuck CLI process. If this runs inside CI, it consumes a CI runner
until the job-level timeout (not an xctriage-level one) kills it. No
partial state is at risk: the worktree is disposable and the real
`repoRoot` was never touched (ADR-004), and no `RemediationStateMachine`
transition or `IdempotencyStore` record happens until `validate` actually
returns, so a killed process leaves no half-written state to clean up.

## What should happen automatically?

Nothing today. This is the most concrete example in this codebase of a
gap `docs/architecture/PART_B` section 44 (quantified NFRs) argues for in
principle — sandbox validation has no stated timeout target, let alone an
enforced one.

## What must a human do?

Kill the CI job (or the local process) manually. Investigate whether the
specific test the patch targets is one that can hang under normal
conditions (a genuinely flaky/hanging test would itself be a
`flakyTest`-category candidate, which is an odd, worth-noting edge case:
remediation for a hang-prone test could itself hang during validation).

## How do I verify recovery?

Re-run with a wall-clock limit wrapped around the invocation
(`timeout 300 xctriage remediate ...` at the CI-job level today, since
`SandboxValidator` has no internal timeout) and confirm it returns a
pass/fail `Result` rather than hanging again.

## Note

This is a real, open gap, not a solved problem being documented after the
fact — flagged here specifically so it doesn't quietly stay invisible.
Adding a timeout to `SandboxValidator.validate` (wrap `Process` execution
with a `Task` that races a `Task.sleep` deadline) is a reasonable next
feature; it hasn't been implemented yet as of this writing.

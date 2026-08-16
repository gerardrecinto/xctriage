# Runbook: `swift build`/`swift test` hangs inside sandbox validation

## What happened?

`SandboxValidator.validate` shells out to `swift build` and `swift test`
inside a disposable git worktree (ADR-004). Like any child process
invocation, it can hang: a deadlocked test, a network call inside a test
that never times out, or (per the pipe-draining comment at the top of
`SandboxValidator.swift`) a chatty process filling a pipe buffer if the
draining logic itself has a bug.

## How do I know?

Since the fix described below, this no longer means "the CLI hangs
forever." A hung step now surfaces as `SandboxValidator.validate` throwing
`TriageError.sandboxTimedOut(command:seconds:)` once the configured
timeout (`--sandbox-timeout`, default 300s per shell-out) elapses.
`Remediate.run()` doesn't catch this specially, so it propagates as a
normal thrown error and the process exits non-zero with that error
description naming the exact command that hung.

## What is the blast radius?

One CLI invocation, bounded now to roughly `timeout` seconds instead of
unbounded. No partial state is at risk: the worktree is disposable and the
real `repoRoot` was never touched (ADR-004), and no
`RemediationStateMachine` transition or `IdempotencyStore` record happens
until `validate` actually returns successfully, so a timed-out attempt
leaves no half-written state to clean up.

## What should happen automatically?

`run(_:_:cwd:timeout:)` in `SandboxValidator.swift` races the subprocess
against a `Task.sleep` deadline in a `withThrowingTaskGroup`; if the
deadline wins, it calls `process.terminate()` (via the
`SandboxProcessHandle` wrapper) to actually kill the hung child process,
not just abandon waiting for it. `test_validate_timesOutRatherThanHangingForever`
in `SandboxValidatorTests` asserts this against a fake tool that sleeps 30s
with a 0.3s configured timeout, and passes in well under a second — proof
the process is actually killed, not just that the error type matches.

## What must a human do?

Investigate whether the specific test the patch targets is one that can
hang under normal conditions (a genuinely flaky/hanging test would itself
be a `flakyTest`-category candidate, which is an odd, worth-noting edge
case: remediation for a hang-prone test could itself hit the sandbox
timeout during validation). If a repository's build/test legitimately
needs longer than the default 300s per step, pass a larger
`--sandbox-timeout`.

## How do I verify recovery?

Re-run `xctriage remediate ... --sandbox-timeout <N>` and confirm it
returns a `sandboxTimedOut` error (or a normal pass/fail `Result`) within
roughly `N` seconds rather than hanging indefinitely.

# ADR-005: Remediation transitions are durable rows, not in-memory or LLM-conversation state

## Context

A single `xctriage remediate --create-pr` invocation runs through several
gates in sequence — eligibility check, patch generation, patch policy
check, sandbox validation, PR creation — each of which can fail and each
of which is a separate process invocation in practice (CI re-triggers the
tool per failure, not as one long-lived session). Before this ADR, none of
that sequence was recorded anywhere: a crash between sandbox validation and
PR creation left no trace that validation had already succeeded.

## Decision

`RemediationStateMachine` (`Sources/XCTriageKit/Remediation/
RemediationStateMachine.swift`) persists every transition as a row in
SQLite, keyed by failure fingerprint. It enforces a fixed predecessor graph
(`patchProposed` → `validating` → `sandboxPassed`/`sandboxFailed`, etc.),
rejects invalid jumps, and treats re-applying the current state as a
no-op rather than an error — so a retried CLI invocation for the same
fingerprint doesn't fail, it just confirms where the attempt already is.

## Alternatives

- **In-memory state, one process per attempt.** What existed before this
  ADR, implicitly: nothing crashed loudly, but nothing was recoverable
  either. A second invocation for the same fingerprint had no way to know
  a first one was in flight or already terminal.
- **Track state in the LLM conversation / agent transcript.** Rejected
  outright, and explicitly called out in `docs/architecture/PART_B` section
  37: "Do not store critical workflow state solely in LLM conversation
  memory." A transcript is not a database — it has no query interface, no
  durability guarantee independent of wherever the conversation happens to
  be stored, and nothing enforces that transitions in it are even legal.

## Why chosen

SQLite gives durability and a queryable history for near-zero added
complexity (see ADR-001). Modeling the predecessor graph as data
(`allowedPredecessors: [State: Set<State?>]`) rather than as scattered
`if` statements in the CLI means the legality of a transition is testable
in isolation from the CLI plumbing that calls it — see
`RemediationStateMachineTests`, which asserts both the happy path and every
rejected transition (skipping a stage, transitioning out of a terminal
state, an unreachable first state).

## Consequences

- The state machine only models stages this codebase can actually reach
  (`patchProposed` through `prOpened`/`prFailed`). It intentionally does
  not model deployment, canary, or rollback states — see ADR-007 for why.
- Callers (currently just `Remediate.run()` in `Sources/xctriage/main.swift`)
  are responsible for calling `transition` at the right points; the state
  machine enforces legality but can't force a caller to call it at all.

## When to revisit

If a state needs to be reachable from more than one predecessor in a way
the current `Set<State?>` model can't express cleanly (e.g. a retry path
that legitimately re-enters `validating` from a state other than
`patchProposed`), or if multiple concurrent workers need to claim a
fingerprint (see the deployment-lease pattern sketched in
`docs/architecture/PART_B` section 42, not yet implemented here since there
is no concurrent worker pool in this codebase today).

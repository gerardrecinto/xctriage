# ADR-008: Remediation is scoped to single-file diffs on a narrow category allowlist

## Context

`PatchGenerator`'s system prompt asks for a diff to exactly one file.
`RemediationPolicy`'s defaults are `maxFilesChanged: 1`, `maxAttempts: 1`,
and `allowedCategories: [.flakyTest, .compilationError]` out of the eight
categories `FailureCategory` defines (the others — `testFailure`,
`resourceExhaustion`, `infraFailure`, `dependencyFailure`, `timeout`,
`unknown` — are not eligible for automated remediation at all today).

## Decision

Keep the default policy narrow: one file, one attempt, two categories.
Widening any of these is a policy config change (and, per ADR-002, a code
change with a test), not something the LLM can opt into per-invocation.

## Alternatives

- **Allow multi-file diffs from the start.** A real compilation error or
  flaky test sometimes genuinely needs a change in more than one place
  (a signature change and its one caller, for instance). Rejected as the
  *default* because a bigger diff is a bigger surface for the sandbox to
  miss something and a bigger review burden for the human approving the
  draft PR — the two things ADR-003 and ADR-004 exist to protect.
- **Allow every failure category.** `testFailure` looks like an obvious
  candidate — it's the most common failure type — but an assertion
  failure is much more likely to indicate a real product regression than
  a flaky test or a broken build script. Auto-generating a "fix" for a
  regression risks papering over the exact thing a human needs to see.
  `compilationError` and `flakyTest` are the two categories where "the
  code doesn't build" or "this test is nondeterministic" are closer to
  mechanical problems than judgment calls.

## Why chosen

Every autonomy boundary in this codebase (single file, two categories, one
attempt, draft-only PRs) is deliberately conservative on the theory that
loosening a limit later is a small, reviewable diff to `RemediationPolicy`
plus a new test, while a limit that turns out to have been too loose can
already have shipped a bad PR. Section 38 of `docs/architecture/PART_B`
frames this as a general principle — deployment/remediation autonomy is a
ladder with explicit levels, and this codebase sits near the bottom rung
by design, not by omission.

## Consequences

- Failures that would benefit from a coordinated multi-file fix simply
  aren't remediated automatically today; they fall through to a human,
  which is the safe failure mode.
- The `maxAttempts: 1` default means a fingerprint that fails remediation
  once (patch rejected, sandbox failed) does not get retried automatically
  by this policy. That's intentional — see `RemediationStateMachine`'s
  terminal states (ADR-005) for how that shows up as durable state, not
  silent looping.

## When to revisit

Once there's a real track record of single-file fixes for
`compilationError`/`flakyTest` being consistently accepted by human
reviewers with few or no changes requested, revisit whether
`allowedCategories` should grow, backed by that data — not backed by "the
model seems capable of more than this."

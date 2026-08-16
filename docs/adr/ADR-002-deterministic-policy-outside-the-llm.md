# ADR-002: The remediation policy gate is deterministic code, not a prompt

## Context

`PatchGenerator` calls Claude to propose a fix. Something has to decide
whether a given failure is even eligible for an automated fix attempt, and
whether the resulting diff is safe enough to become a PR. That decision
could live inside the system prompt ("only propose fixes for flaky tests
and compilation errors, and only touch one file") and rely on the model to
follow it.

## Decision

`RemediationPolicy` (`Sources/XCTriageKit/Policy/RemediationPolicy.swift`) is
a plain Swift struct with no LLM call in it. It runs twice: once before
patch generation (`isEligibleForRemediation` — category allowlist, minimum
confidence, attempt count) and once after (`isPatchAllowed` — file count,
forbidden path prefixes including its own source file and `.github/`). Both
return a `Decision` enum the CLI checks with a plain `guard`.

## Alternatives

- **Prompt-based policy.** Put the same rules in `PatchGenerator`'s system
  prompt and trust the model to self-censor. Cheaper to write, but the
  policy becomes unauditable (you can't unit test a sentence in a prompt)
  and unenforceable (a sufficiently unusual failure description can talk
  the model out of a rule stated in English).
- **Policy as a second LLM call** ("ask a classifier model whether this
  patch is safe"). Still probabilistic, still a second point of failure,
  still not something you can write a deterministic unit test against.

## Why chosen

A `guard case .allowed = eligibility else { ... }` either compiles and
passes its unit tests or it doesn't — there's no ambiguity about whether
the policy actually ran. `RemediationPolicyTests` exercises every branch
(category not allowed, confidence too low, attempt limit exceeded, forbidden
path, too many files changed) as ordinary assertions, not prompt evals.

## Consequences

- Every new autonomy rule (a new forbidden path, a stricter confidence
  floor) is a code change with a test, not a prompt edit that has to be
  manually re-evaluated for regressions.
- The policy can't express anything context-dependent that isn't already
  computed upstream (category, confidence, file paths, attempt count). If a
  future rule genuinely needs semantic judgment ("does this diff change
  business logic or just formatting?"), that judgment still has to resolve
  to a concrete signal the deterministic gate can check — the gate itself
  stays LLM-free.

## When to revisit

If policy rules grow past what a flat struct comfortably expresses (e.g.
per-repository policy config, org-level overrides), move to a small
declarative policy format (OPA/Rego-style, per `docs/architecture/PART_B`
section 99) rather than letting the Swift struct grow a rule interpreter of
its own. Not needed yet — there are five rules, not fifty.

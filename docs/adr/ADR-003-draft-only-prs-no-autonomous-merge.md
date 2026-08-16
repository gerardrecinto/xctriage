# ADR-003: xctriage only ever opens draft PRs; nothing in this codebase merges

## Context

`GitHubPRWriter.createDraftPR` is the only code path in this repo that
writes to a real GitHub repository. It's reachable from
`xctriage remediate --create-pr`, and CI wires the same flag into
`.github/workflows/ci.yml` for `compilation_error` failures on its own PRs.

## Decision

`GitHubPRWriter` always passes `--draft` to `gh pr create` and never invokes
`gh pr merge`, `git push --force` to a protected branch, or anything else
that could land a change without a human clicking merge. This isn't a
runtime flag — there is no code path in this type that can open a
non-draft PR or merge one.

## Alternatives

- **Auto-merge low-risk categories.** Section 38 of
  `docs/architecture/PART_B` sketches deployment autonomy levels up to
  "approved low-risk remediation classes can fully auto-deploy" — but that
  ladder starts above where this codebase currently sits. Auto-merging
  even a single-file, sandbox-validated, policy-allowed diff still means
  code an LLM wrote lands on `main` with no human in the loop.
- **Configurable merge behavior** (a flag like `--auto-merge` gated by
  category). Rejected for the same reason `RemediationPolicy` doesn't have
  an LLM-decided "this looks safe" branch: giving the tool a merge
  capability at all, even behind a flag defaulted to off, means a future
  change to that default is a one-line diff instead of a new capability
  that has to be built from scratch.

## Why chosen

The failure mode this avoids isn't "the patch is wrong" — sandbox
validation already catches that. It's "the patch is right for the wrong
reason," "it duplicates a fix already in flight," or "it's technically
correct but not what a maintainer would actually want here." A human
reviewing a draft PR catches those; nothing in this pipeline can.

## Consequences

- Every automated fix requires a human to read and merge it, which is a
  real throughput ceiling. That's accepted as the cost of the guarantee.
- `RemediationStateMachine`'s `prOpened` state (see ADR-005) is explicitly
  the terminal, successful state for this tool's part of the pipeline —
  there is no `merged` or `deployed` state in the state machine, because
  this codebase has no way to observe or cause either.

## When to revisit

Only after a long enough track record of draft PRs from this tool being
merged essentially as-is for a specific, narrow failure category — and even
then, per section 38, that decision belongs to a deterministic policy
engine reading real merge/revert history, not to the LLM deciding for
itself that a given diff "looks safe enough."

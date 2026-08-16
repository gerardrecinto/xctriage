# Runbook: a fingerprint appears to have opened two PRs

## What happened?

`IdempotencyStore` (ADR-006) is supposed to make this impossible for a
given `(operation: "create_pr", key: fingerprint)` pair — the second
`xctriage remediate --create-pr` invocation for the same fingerprint
should short-circuit on `existingResult` and print the first PR's URL
instead of opening a new one. If two real PRs exist for the same
fingerprint, something in that guarantee broke.

## How do I know?

Check `~/.xctriage/idempotency.db` (or whatever `--idempotency-db` path
was used) for the fingerprint:

```
sqlite3 ~/.xctriage/idempotency.db \
  "select * from processed_operations where operation='create_pr' and key='<fingerprint>';"
```

If there's exactly one row, but two PRs exist on GitHub, the two runs used
*different* db paths (e.g. one CI runner's `~/.xctriage/` isn't the same
filesystem as another's, or `--idempotency-db` was passed inconsistently)
— the dedup guarantee is per-database-file, not global. If there's no row
at all despite a PR existing, `recordProcessed` was never reached — check
whether the run crashed between `createDraftPR` succeeding and the
`try await idempotency.recordProcessed(...)` call in `Remediate.run()`
(main.swift), which would be a real gap: a duplicate is still possible in
that narrow window today.

## What is the blast radius?

Two open draft PRs proposing the same fix. Nothing merges automatically
(ADR-003), so the actual risk is reviewer confusion and wasted CI minutes
validating both, not a bad merge.

## What should happen automatically?

Nothing beyond the idempotency check itself — there is no background
reconciliation job that notices and closes duplicate PRs after the fact.

## What must a human do?

Close the duplicate PR (keep whichever has a passing sandbox result /
better rationale), and if the cause was inconsistent `--idempotency-db`
paths across runners, fix the CI config to point every runner at the same
persistent path (or, if runners are genuinely isolated with no shared
filesystem, that's a real architectural gap — see ADR-001's note that
`IdempotencyStore` assumes a single writer's filesystem, not a distributed
one).

## How do I verify recovery?

Re-run `xctriage remediate ... --create-pr` for the same fingerprint
against the now-correct db path and confirm it prints "PR already opened
for fingerprint [...]" instead of opening a third PR.

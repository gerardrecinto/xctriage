# ADR-006: Dedup via a SQLite UNIQUE constraint, not a distributed idempotency service

## Context

`xctriage remediate --create-pr` can be triggered more than once for the
same underlying failure: a CI job that retries after a transient failure,
a human re-running the command by hand after seeing a confusing error, or
(once webhook-triggered runs exist) a redelivered webhook. Before this
ADR, a second run for a fingerprint that already had an open PR would
either fail obscurely (the deterministic branch name in `GitHubPRWriter`
already collides on a retry) or, worse, could succeed and open a second PR
for the same fix.

## Decision

`IdempotencyStore` (`Sources/XCTriageKit/Remediation/IdempotencyStore.swift`)
records `(operation, key) → result` in a SQLite table with a
`UNIQUE(operation, key)` constraint, written with `INSERT OR IGNORE`. The
CLI checks `existingResult(operation: "create_pr", key: fingerprint.value)`
before doing any work — before even generating a patch — and if a result
exists, prints it and returns instead of repeating the side effect.

## Alternatives

- **Rely on GitHubPRWriter's deterministic branch name to fail loudly on a
  retry.** This is what happened implicitly before: `git checkout -b
  xctriage/remediate-<fingerprint>` on an existing branch fails, so a
  retry does error out rather than silently duplicating work — but only
  after spending LLM tokens generating a patch and sandbox time validating
  it, and the failure mode is "the tool crashed," not "the tool recognized
  this was already handled."
- **A message-queue-level dedup mechanism** (e.g. a Kafka consumer group
  with exactly-once semantics). Would require an actual queue in front of
  this tool, which doesn't exist — `xctriage remediate` is invoked
  directly by CI or a human, not consumed off a queue. Building queue
  infrastructure to solve a problem a `UNIQUE` constraint already solves
  would be the over-engineering `docs/architecture/PART_B` section 110
  explicitly warns against.

## Why chosen

`INSERT OR IGNORE` is atomic at the SQLite level: two processes racing to
record the same `(operation, key)` can't both "win" and produce two
different recorded results. Checking `existingResult` before doing any
work (rather than after, as a last-second guard) also means a duplicate
trigger costs nothing beyond a database read — no wasted LLM call, no
wasted sandbox build.

## Consequences

- Idempotency is scoped to whatever `key` the caller passes. Today that's
  the failure fingerprint alone; the same fingerprint after a code change
  that alters the failing file will still look like "already handled"
  until a human clears it (there's no TTL or invalidation — see the "When
  to revisit" note).
- This only guards `xctriage`'s own side effects (currently just PR
  creation). It says nothing about idempotency on GitHub's side (e.g. `gh
  pr create` itself being retried at the network level) — that's a
  separate, already-solved problem (`gh` surfaces a clear error on a
  duplicate branch).

## When to revisit

If the key needs finer granularity — e.g. fingerprint + commit SHA, so a
fix for the same underlying bug at a later commit isn't treated as
"already handled" forever — change what the caller passes as `key`, not
the store itself; `IdempotencyStore` is deliberately key-agnostic. If this
tool grows a real trigger queue (GitHub webhooks landing on an HTTP
endpoint rather than a human/CI running the CLI directly), revisit whether
SQLite is still the right store per ADR-001's "single-writer" assumption.

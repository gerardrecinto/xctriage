# ADR-001: SQLite for local durable state

## Context

`FlakyTestTracker`, `RemediationStateMachine`, and `IdempotencyStore` all need
to persist data across process restarts: flaky-test history, remediation
transition history, and dedup keys for retried triggers. xctriage runs as a
CLI invoked from CI or a developer's machine — it is not a long-running
server with a fleet of workers writing to shared state concurrently.

## Decision

Use an embedded SQLite database file per concern (`flaky.db`,
`remediation_state.db`, `idempotency.db`), written through a small
actor-wrapped DAO in each type. No external database process, no network
connection, no schema migration framework.

## Alternatives

- **Postgres.** Real concurrency control, real migrations, a real client
  library. Requires a running server, connection credentials, and network
  access — none of which a CI runner or a developer's laptop reliably has
  for a tool that's supposed to "just work" after `swift build`.
- **Flat JSON/plist files.** No dependency at all, but no atomic
  read-modify-write, no indexing, and hand-rolled concurrency safety for
  every new table shape.
- **In-memory only.** Simplest of all, but defeats the entire purpose of
  section 37/43 in `docs/architecture/PART_B`: recoverability after a
  crash and dedup across separate process invocations both require the
  state to outlive the process.

## Why chosen

SQLite is a single file, ships with the OS, needs no server, and gives real
transactions, indexes, and a `UNIQUE` constraint for idempotency almost for
free. Every consumer in this codebase is a single process reading/writing
its own db file — SQLite's known weak spot (many concurrent writers) is not
this tool's shape.

## Consequences

- No fan-out to multiple xctriage worker processes sharing one state file
  without adding real concurrency handling (busy-timeout, WAL tuning, or
  moving that specific store off SQLite).
- No built-in migration tooling; schema changes are additive `CREATE TABLE
  IF NOT EXISTS` / `ALTER TABLE` statements reviewed by hand.
- Db files live under `~/.xctriage/` by default and are not synced or
  backed up by this tool — see the Disaster Recovery gap noted in
  `docs/architecture/PART_B` section 57 (proposed target, not implemented).

## When to revisit

If xctriage grows a real multi-worker control plane (queue consumers, an
API server, concurrent CI runners writing to the *same* db) rather than
one-process-per-invocation, move the shared stores to Postgres at that
point — not before. Speculatively adding Postgres today for a single-writer
CLI would be the "architecture astronautics" this project's own design
notes (section 110) explicitly warn against.

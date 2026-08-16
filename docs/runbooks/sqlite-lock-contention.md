# Runbook: SQLite `database is locked` from FlakyTestTracker / RemediationStateMachine / IdempotencyStore

## What happened?

All three durable stores in this codebase (`FlakyTestTracker`,
`RemediationStateMachine`, `IdempotencyStore` — ADR-001) open the same
kind of SQLite file with `PRAGMA journal_mode=WAL`. WAL mode allows one
writer and multiple readers concurrently, but two *writers* to the same
db file at the same time still contend, and a long-running writer (or a
crashed process that never closed its connection) can leave the db
effectively locked for others.

## How do I know?

Any of the three stores' `execute`/`query` helpers throw
`TriageError.parseError("Execute failed: database is locked")` (or
similar SQLite error text from `sqlite3_errmsg`) when this happens. It
surfaces as a normal thrown Swift error propagating out of whichever CLI
command was running.

## What is the blast radius?

Scoped to whichever db file is contended — `flaky.db`,
`remediation_state.db`, and `idempotency.db` are separate files by
default, so lock contention on one doesn't affect the others. Per
ADR-001, this is expected to be rare in the current single-process-per-
invocation usage pattern; it becomes more likely if multiple CI runners
share one filesystem path (e.g. a shared `~/.xctriage/` on a persistent
CI cache volume) and run concurrently.

## What should happen automatically?

Nothing today — none of the three stores set a `busy_timeout` or retry on
`SQLITE_BUSY`. A concurrent write attempt fails immediately rather than
waiting briefly for the other writer to finish.

## What must a human do?

If this is a one-off (a leftover `.db-wal`/`.db-shm` file from a crashed
process holding a stale lock), check for and remove orphaned `-wal`/`-shm`
files only after confirming no process still holds the db open (`lsof
<path>`). If this is a recurring pattern (multiple CI runners genuinely
racing to write to the same shared db path), separate the db path per
runner (e.g. by build ID) or accept that this specific setup needs a real
multi-writer database — see ADR-001's "When to revisit."

## How do I verify recovery?

Re-run the failed command against the same db path and confirm it
completes without a locked-database error. `sqlite3 <path> "pragma
integrity_check;"` confirms the file itself wasn't corrupted by the
contention (WAL mode makes this unlikely, but worth checking after any
crash-related lock).

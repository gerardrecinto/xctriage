# Runbook: GitHub rate limit during `--create-pr`

## What happened?

`GitHubPRWriter` shells out to `git push` and `gh pr create` (`Sources/
XCTriageKit/Remediation/GitHubPRWriter.swift`). If the token behind `gh`
has hit GitHub's API rate limit, `gh pr create` exits non-zero.

## How do I know?

`GitHubPRWriter.createDraftPR` wraps every shell-out in `exec(...)`, which
throws `TriageError.remediationCommandFailed(command, output)` on a
non-zero exit. The thrown error's `output` string contains `gh`'s stderr,
which for a rate limit looks like `API rate limit exceeded` or (for
secondary rate limits) `You have exceeded a secondary rate limit`.

In the CLI, this surfaces as `Remediate.run()` propagating the thrown
error and the process exiting non-zero — there is no special-cased
handling for this specific failure today.

## What is the blast radius?

Just this one invocation. The patch was already generated and passed
sandbox validation (`--create-pr` requires sandbox to have run — see
`Remediate.run()`'s refusal of `--create-pr` with `--skip-sandbox`) before
the PR step runs, so no work is lost: `sandboxResult` and `proposal` are
still valid, only the `gh pr create` call failed.

Because the idempotency check (`IdempotencyStore.existingResult`, ADR-006)
runs *before* patch generation and only records success after a PR
actually opens, a rate-limited failed run leaves no idempotency record —
the next retry is treated as a first attempt, correctly.

## What should happen automatically?

Nothing today. There is no retry-with-backoff around the `gh` shell-out.
This is a known, accepted gap for a tool whose current trigger is a human
or CI re-running the command, not an automated retry loop.

## What must a human do?

Re-run `xctriage remediate ... --create-pr` once the rate limit window
resets (GitHub reports the reset time in the `X-RateLimit-Reset` header;
`gh`'s error text usually doesn't surface it directly — check `gh api
rate_limit` separately if needed). The re-run is safe: the state machine
(ADR-005) has no `prOpened` transition recorded, so this isn't a duplicate
attempt, it's a legitimate retry of one that never completed.

## How do I verify recovery?

Re-run the same command and confirm it prints `Opened draft PR on branch
...` with a real PR URL. Check `IdempotencyStore`'s db
(`~/.xctriage/idempotency.db` by default) has exactly one row for that
fingerprint's `create_pr` operation afterward.

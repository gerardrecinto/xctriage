# What I Deliberately Did Not Build

Every item below was considered — it appears somewhere in `docs/architecture/PART_A` through `PART_D` as target design — and deliberately not built, not forgotten. The test for inclusion here isn't "would this be interesting," it's "what problem does this solve *today*, for the code that actually exists." Where the honest answer was "none yet," the thing stayed out.

This list is maintained alongside the ADRs in `docs/adr/` — several entries here point at the ADR that made the call explicit. It exists as its own doc rather than buried in `PART_B` because "what's missing and why" deserves to be found without reading 800 lines of target architecture first.

## Kubernetes, Argo CD, GitOps reconciliation

**Not built.** There is no cluster, no manifests, no reconciler. `xctriage`'s own remediation loop ends at a draft PR (ADR-003) — nothing downstream of that PR exists in this codebase to deploy anything anywhere.

**Why:** building a fake reconciler that reconciles nothing real would teach nothing about the actual hard parts of GitOps (drift detection against a live API server, webhook timing, RBAC boundaries) and would misrepresent what this project is, which is exactly what ADR-007 exists to prevent.

**What would justify building it:** an actual target environment to deploy to — even a single local/dev cluster, per the recommended MVP vertical slice in the target-architecture docs. Not before.

## Kafka / any event bus

**Not built.** `xctriage remediate` is invoked directly by a human or by CI — there is no producer, no consumer, no topic, anywhere in this codebase.

**Why:** an event bus solves a fan-out and backpressure problem this tool doesn't have yet. One CLI invocation handling one failure at a time, synchronously, is simpler and correct for the actual current trigger pattern (direct invocation, not a stream of inbound events).

**What would justify building it:** a real trigger source producing failures faster than they can be processed one at a time — e.g. genuine webhook-driven triage across many repositories. `docs/architecture/PART_B` section 49 sketches what that would need (fingerprint-based dedup before fan-out); none of it is wired to anything today.

## Terraform-provisioned cloud infrastructure

**Not built.** No cloud account, no `.tf` files, no state backend, nothing provisioned. `SQLite` files under `~/.xctriage/` are the entirety of this project's "infrastructure" (ADR-001).

**Why:** there's nothing to provision for a Swift CLI that shells out to `git`/`swift`/`gh` and calls one external API. Infrastructure-as-code for infrastructure that doesn't need to exist is the "architecture astronautics" this project's own design notes explicitly warn against.

## Multi-region / active-active deployment

**Not built, not designed in detail.** `docs/architecture/PART_B` gestures at "active control region + warm standby" as a starting point, but even that is unimplemented and untested — there's one machine running one CLI process at a time.

**Why:** premature for a project with no deployed service to make regional at all.

## Postgres (in place of SQLite)

**Not built.** All three durable stores in this codebase (`FlakyTestTracker`, `RemediationStateMachine`, `IdempotencyStore`) use SQLite.

**Why:** see ADR-001 in full — the short version is that every writer is a single process on a single machine today, which is exactly SQLite's strong case and exactly the situation where a Postgres server, connection pool, and migration framework would be pure overhead with nothing to show for it.

## A vector database / semantic retrieval index

**Not built.** There is no embedding generation, no similarity search, no historical-failure retrieval beyond `FailureFingerprint`'s exact-match hashing.

**Why:** fingerprinting (category + normalized failure site, SHA-256'd) already solves the actual problem this codebase has today — deduplicating near-identical reruns of the same failure. Semantic similarity search solves a different, harder problem (finding *related but not identical* historical failures) that nothing in this codebase currently needs, because there's no corpus of historical failures large enough yet to make exact-match fingerprinting insufficient.

## Redis / any cache layer

**Not built.** Nothing in this codebase has a latency or load profile that needs a cache in front of it — `RuleClassifier` is a synchronous, in-process rule match; SQLite reads for fingerprint/state lookups are already fast at the scale of "one CLI invocation, one lookup."

**Why:** a cache without a demonstrated read-heavy hot path to protect is a dependency with no job.

## Neo4j / any graph database

**Not built.** The "failure memory" relationships described conceptually in the target docs (a failure linked to a Jira ticket, a PagerDuty incident, a PR, a prior similar failure) have no code representation at all today — there's no Jira or PagerDuty integration to produce those links in the first place.

**Why:** a graph database models relationships between things that don't yet exist in this system. Foreign keys in a normal relational schema would be more than sufficient for the actual relationship density this project has today (essentially none, outside `RemediationStateMachine`'s single-key history), if and when those integrations get built.

## Chaos engineering rig / game-day tooling

**Not built** as running infrastructure. `docs/architecture/PART_B` section 66 lists chaos scenarios (GitHub 500s, LLM timeouts, Postgres failover, etc.) as a target design; none of it is automated or runs anywhere.

**Why:** chaos testing validates resilience of a system under real operational load and real dependency graphs. This codebase's actual dependency graph today is small enough (SQLite files, `git`/`swift`/`gh` shell-outs, one HTTP API) that the runbooks in `docs/runbooks/` — written by reasoning through each real failure mode by hand — cover the same ground more honestly than a chaos harness would for a system this size.

## Grafana dashboards / a metrics pipeline

**Not built.** No Prometheus, no OpenTelemetry exporter, no dashboard JSON, anywhere in this repo.

**Why:** there's no running service to have golden signals for. `swift test` output and this codebase's own CI logs are the only "observability" that exists, and they're sufficient for a CLI tool with no uptime to measure.

## Jira / PagerDuty integrations

**Not built.** No API client for either exists in this codebase.

**Why:** these solve a human-notification and incident-tracking problem that only matters once remediation runs frequently enough, and involves enough people, that draft PRs alone stop being sufficient signal. That threshold hasn't been reached by a project whose remediation trigger is "a human or CI runs one CLI command."

## What this list is not

This isn't a roadmap and it isn't a promise any of the above ships next. It's a record of a decision already made: build the parts of a 114-point platform-engineering spec that are real, testable, and honestly describable — and say plainly, in one place, what the rest is instead of quietly letting a 800-line target-architecture document imply more than the code backs up.

# Target Architecture - Part B (Sections 34-114)
## Continuous deployment, system-design depth, observability, and documentation strategy for xctriage at platform scale.

This is a target-architecture design-review document, not a description of what xctriage currently runs. The real repo is a Swift 6 CLI: `BuildLogParser`/`XCResultParser` for input, a 17-rule `RuleClassifier` across 7 categories, a `ClaudeClassifier` fallback below 0.60 confidence, `FailureFingerprint` (SHA256, 16 hex chars), a two-gate `RemediationPolicy`, a `PatchGenerator` that proposes a single-file diff and never applies it, a `SandboxValidator` that builds and tests that diff inside an ephemeral `git worktree`, and a `remediate` CLI subcommand wiring all of it together. 104 tests pass (MEASURED). There is no event bus, no Kubernetes, no GitOps controller, no multi-region deployment, no Grafana instance, and no chaos-engineering rig actually running today. Every number below is tagged **(MEASURED)** when it comes from the real repo or **(TARGET)** when it's a proposed design goal with no production evidence behind it yet. This continues from Part A (sections 1-33, the agentic pipeline / MCP / agent-architecture half of the same design review) in this directory.

The throughline across all 81 sections below: the two deterministic gates that already exist in the real code (`RemediationPolicy.isEligibleForRemediation`, `RemediationPolicy.isPatchAllowed`) and the real sandbox (`SandboxValidator`) do not change shape as this system grows. Continuous deployment, canaries, and rollback are the same idea one layer up: the LLM proposes a change, and everything that decides whether that change is safe to exist, safe to build, and safe to run in production is deterministic code you can unit test. Autonomy grows by adding more deterministic gates downstream of the model, never by trusting the model more.

---

## 34. Continuous Deployment Must Be a First-Class Architecture

**(TARGET)** Today xctriage's remediation loop ends at "sandbox-validated diff, printed or written to a file" - there is no merge, build-artifact, or deployment step after it (MEASURED: the `remediate` CLI command's last action is `print(header + proposal.unifiedDiff)` or a file write). The target architecture extends the loop through the rest of the software lifecycle:

```
commit -> CI -> build -> test -> xctriage -> failure intelligence
   -> AI remediation -> candidate PR -> PR validation -> human approval
   -> merge -> immutable artifact -> GitOps desired state -> CD
   -> canary -> SLO validation -> production -> post-deploy verification
   -> observability feedback into xctriage's failure memory
```

A remediation is not "successful" at merge. It is successful only when: the original failure fingerprint no longer reproduces, CI passes on the merged commit, the deploy that ships it stays inside SLO through its canary windows, and the fingerprint does not recur during a defined post-deploy verification window. This closes the loop that Part A's agent architecture (sections 1-33) leaves open: today, "PR opened" is the last verifiable state; the target state is "verified fixed in production."

## 35. Separate CI and CD Architecturally

**(TARGET)** CI and CD are different failure domains with different blast radii, and conflating them is how a CI credential ends up with production write access.

**CI** (today: MEASURED, via Jenkinsfile + `.github/workflows/ci.yml`): commit -> build -> `swift test` -> xctriage -> SAST -> SCA -> ends when it has produced a trusted, immutable artifact. CI's job is proving a commit is buildable and testable; it never needs to know what's running in production.

**CD** (TARGET, does not exist yet): immutable artifact -> desired-state update -> GitOps reconciliation -> deploy -> canary -> health check -> promote or roll back. CD's job is proving a known-good artifact is safely running; it never needs source-repository write access.

The seam between them is the artifact digest, not a rebuild: **build once, promote everywhere, never rebuild for production.** This is the same reason xctriage's own two policy gates are separate methods (`isEligibleForRemediation` vs `isPatchAllowed`, MEASURED) rather than one combined check - different question, different inputs, different failure mode if you get it wrong.

## 36. GitOps-Based Continuous Deployment

**(TARGET)** Push CD means the CI/AI system holds standing production credentials and writes into the cluster directly - compromise CI, compromise production. Pull CD means Git holds the desired state and an in-cluster reconciler (Argo CD or Flux) pulls and applies it; the CI/AI system never touches the cluster.

```
AI-generated PR -> human review -> merge -> CI builds artifact (sha256:abc...)
   -> manifest repo: image.digest = sha256:abc...
   -> Argo CD: fetch desired state -> diff against live state -> sync
   -> Argo Rollouts: 5% -> 25% -> 50% -> 100%
```

A GitHub webhook, if wired up, only wakes the reconciler early - it is a poke, not a push. The reconciler still pulls and re-derives desired state itself, so a missed or duplicated webhook never causes drift; the next scheduled reconciliation loop corrects it regardless. This is the deployment-layer version of `SandboxValidator`'s "the model proposes, deterministic code decides" pattern (MEASURED): xctriage/CI never gets write access to the cluster, only to Git.

## 37. Continuous Deployment State Machine

**(TARGET)** A durable, persisted state machine, not agent conversation memory, tracks an AI-generated fix from proposal to verified production fix:

```
PATCH_PROPOSED -> PATCH_VALIDATING -> PR_OPEN -> AWAITING_HUMAN_REVIEW
  -> PR_APPROVED -> MERGED -> ARTIFACT_BUILDING -> ARTIFACT_SIGNED
  -> DESIRED_STATE_WRITTEN -> RECONCILING -> CANARY_5 -> CANARY_25
  -> CANARY_50 -> CANARY_100 -> VERIFYING -> REMEDIATION_CONFIRMED

failure branches: PATCH_REJECTED, VALIDATION_FAILED, SECURITY_POLICY_BLOCKED,
  DEPLOYMENT_FAILED, CANARY_FAILED, SLO_REGRESSION, ROLLBACK_REQUESTED,
  ROLLING_BACK, ROLLED_BACK, ROLLBACK_FAILED, NEEDS_HUMAN
```

`PATCH_VALIDATING` is exactly what `SandboxValidator.validate` already does today (MEASURED: applies the diff in an ephemeral worktree, builds, runs the target test). Every transition would be persisted to a table (see section 52), recoverable after a process restart - an AI workflow's state must never live only inside an LLM's conversation context.

## 38. Continuous Deployment Autonomy Levels

**(TARGET)** Deployment autonomy is a separate ladder from code-generation autonomy, and today xctriage sits at the bottom rung of both:

| Level | Capability | xctriage today |
|---|---|---|
| 0 | Investigates only | -- |
| 1 | Suggests a patch | MEASURED: `PatchGenerator.proposePatch` |
| 2 | Opens a draft PR | MEASURED: `GitHubPRWriter.createDraftPR`, wired into `xctriage remediate --create-pr` and into this repo's own CI for `compilation_error` failures. Always `--draft`; see ADR-003. |
| 3 | PR can merge after human approval | not built - and by design, per ADR-003 there is no code path in this repo that can merge a PR at all, not even behind a flag |
| 4 | Auto-deploys fixes to dev | not built |
| 5 | Auto-deploys fixes to staging | not built |
| 6 | Auto-begins production canary | not built |
| 7 | Fully auto-deploys approved low-risk classes | not built |

The deterministic policy engine decides the ceiling, never the model. `RemediationPolicy` already encodes this instinct at level 1 (MEASURED: category allowlist, confidence floor, forbidden paths) - extending it to levels 4-7 means adding deployment-scoped fields (environment, risk tier) to the same struct, not inventing a new mechanism.

## 39. Production Canary Design

**(TARGET)** Progressive traffic shift for an AI-generated fix, gated on multiple consecutive healthy windows, never a single datapoint:

```
stable v42: 95% | candidate v43: 5%   -- health passes for N windows --v
stable v42: 75% | candidate v43: 25%  -- health passes --v
stable v42: 50% | candidate v43: 50%  -- health passes --v
stable v42: 0%  | candidate v43: 100%
```

Signals: p50/p95/p99 latency, error rate, crash rate, saturation, and any test-specific application metric. **Require several consecutive healthy windows before promoting; never roll back or promote off one noisy sample.** This is the production analog of `SandboxValidator` requiring both `buildSucceeded` and `testSucceeded` to be true (MEASURED) before a proposal is ever surfaced - a canary gate is the same "prove it, don't just claim it" instinct applied to live traffic instead of a build.

## 40. Automated Rollback Architecture

**(TARGET)** Rollback is a forward compensating transaction, not an "undo":

```
desired state: v43 (candidate)
   health failure detected
   write new desired state: v42 (last known good)
   Argo CD observes: Git says v42, cluster says v43 -> diff -> sync
   traffic returns to v42
```

This is a Saga compensation pattern: nothing is deleted or reverted in place, a new "go back to v42" intent is written and reconciled the same way any other desired-state change is. It interacts with immutable artifacts (v42's artifact still exists, was never rebuilt), Git history (the rollback is itself a commit, auditable), and the remediation state machine (transitions to `ROLLED_BACK`, not silently discarded). An AI-generated fix that gets rolled back should reopen its originating Jira/incident link automatically rather than vanish.

## 41. Database Migration Safety

**(TARGET)** The edge case that breaks a shallow CD design: an AI-generated code fix that needs a schema change. Use expand-contract, never a single destructive migration in the same release as the code that depends on it:

```
Release N:   ADD new_column (nullable) -> old code works, new code works
             -> backfill data
Release N+1: old code retired -> DROP old_column
```

**An AI remediation agent must never be permitted to autonomously run a destructive migration** (DROP, column type narrowing, non-nullable ADD without a default). This is a direct extension of the forbidden-path pattern already in `RemediationPolicy` (MEASURED: `forbiddenPathPrefixes` blocks `Policy/`, `Classifiers/`, `.github/`, `Package.swift`) - a target implementation adds a migration-risk classifier ahead of the same gate, and destructive migrations are rejected the same deterministic way a two-file diff is rejected today.

## 42. Deployment Concurrency Protection

**(TARGET)** Two deployments racing for the same `(service, environment)` need a lease, and a lease alone is not enough - a worker that stalls, loses its lease on timeout, then wakes up and resumes writing is a real bug class. Use a monotonically increasing fencing token:

```
lease { lease_id, fencing_token, owner, expires_at }
worker A acquires lease, fencing_token = 7
worker A stalls past expiry; worker B acquires lease, fencing_token = 8
worker A wakes up, tries to write with token 7 -> rejected (stale token < 8)
```

A timeout alone only prevents two workers from *starting* concurrently; the fencing token is what prevents a *resumed* stale worker from continuing to mutate state after it's lost ownership. Nothing in xctriage today holds a deployment-scoped lease (MEASURED: no deployment system exists), so this is a clean net-new component in the target design, not a retrofit.

## 43. End-to-End Idempotency

**(TARGET)** Delivery is at-least-once everywhere in this system, never exactly-once, and every consumer needs an explicit idempotency key:

```
GitHub webhook redelivery      -> processed_events(provider, event_id) UNIQUE
Remediation submission          -> Idempotency-Key: fingerprint + commit SHA
Artifact identity               -> sha256(content)
PR creation                     -> dedup on fingerprint + remediation generation
Jira ticket creation             -> fingerprint stored as a custom field
PagerDuty incident               -> dedup_key = fingerprint
```

`FailureFingerprint` (MEASURED, SHA256 over category+file+test+normalized message, 16 hex chars) is already the idempotency key this whole target system would key off of - a fingerprint that survives duplicate delivery is a fingerprint that survives duplicate CI events, duplicate webhook retries, and duplicate agent re-runs, because it was designed to be stable across repeated runs of the same underlying failure in the first place.

## 44. System-Design NFRs

**(TARGET)** Every number below is a proposed target with zero production measurement behind it. Never state these as achieved.

| Path | Target |
|---|---|
| Failure ingestion | p99 < 500ms |
| xctriage parse (typical .xcresult) | < 5s |
| Fingerprint lookup | p99 < 100ms |
| Historical correlation | p99 < 500ms |
| Agent triage | < 2 min |
| PR generation | < 5 min |
| Rollback traffic shift | < 5s |
| Metrics freshness | < 5s |
| End-to-end automated triage | < 3 min |
| Critical incident alert | < 60s after classification |

(MEASURED, for contrast, real numbers from this session: `swift build` ~1-2s incremental, full `swift test` suite ~1.6-2s for 104 tests, single `SandboxValidator` fake-tool test run 0.1-0.4s each - none of these are the target production numbers above; they're local dev-loop numbers on one machine.)

## 45. Availability Tiers

**(TARGET)** Not every component deserves the same number:

| Tier | Target | Components |
|---|---|---|
| 99.95% | Deployment control plane | GitOps reconciler, lease service |
| 99.9% | Failure ingestion, remediation orchestration | event ingestion, agent workers |
| 99.5% | Dashboards, analytics | Grafana, query UI |

Composed availability across serial dependencies multiplies, it doesn't average: three services each at 99.95% in series compose to roughly 99.85% (0.9995^3), not 99.95%. A design that chains five "four-nines" services in series without redundancy at each hop has quietly built a three-nines system. State this math explicitly rather than asserting a single end-to-end number.

## 46. PACELC / CAP Where It Actually Matters

**(TARGET)** Apply this only to actual state stores, not to every component in the diagram. The question per store: is being *wrong* worse than being *stale*?

| Store | Classification | Why |
|---|---|---|
| Deployment version pointer | PC/EC | wrong deploy target is unsafe |
| Workflow ownership lease | PC/EC | wrong owner double-mutates state |
| Git desired state | PC/EC | wrong desired state deploys the wrong artifact |
| Security policy | PC/EC | stale-permissive policy is a vulnerability |
| Dashboard analytics | PA/EL | a 5-second-stale count is fine |
| Historical similarity cache | PA/EL | slightly stale match is still useful |

`RemediationPolicy`'s two gates (MEASURED) are PC/EC by nature even though they're not distributed today - they must be evaluated against current, correct policy, never a cached or stale copy, because being wrong there means an unsafe patch escapes review.

## 47. Capacity Estimation

**(TARGET)** Full worksheet, explicit assumptions, recalculable if the assumptions change:

```
Assume: 500 engineers x 3 commits/engineer/day = 1,500 builds/day
Failure rate assumption: 10% of builds fail                 -> 150 failure events/day
Agent-trigger-worthy fraction: 30% (rest handled by 17 rules alone) -> 45 agent runs/day

Trigger QPS (avg):  1500 / 86400          ~= 0.017 req/s
Peak factor: 3x (CI load concentrates around business-hours PR pushes)
Peak QPS: ~0.05 req/s

Concurrent CI jobs (Little's Law, L = lambda x W):
  lambda = 1500/86400 jobs/s, W = ~8 min avg build time (480s)
  L = 0.017 x 480 ~= 8 concurrent builds in steady state

Concurrent AI investigations:
  lambda = 45/86400 agent-runs/s, W = 2 min (TARGET, section 44)
  L = 0.00052 x 120 ~= 0.06 -> effectively always <1 concurrent, no pool pressure at this scale

Artifact storage: 1500 builds/day x 500MB avg artifact x 14-day PR retention
  ~= 10.5 TB rolling PR-artifact storage (release artifacts retained separately, longer)

LLM tokens: 45 agent runs/day x ~3,000 tokens/call (context + response) x 3 calls/run avg
  ~= 405,000 tokens/day -> ~12.2M tokens/month
```

This whole worksheet is TARGET-scale math for a hypothetical 500-engineer org; xctriage today has no multi-repo, multi-engineer telemetry to calculate an actual number from (MEASURED: it's a single-user CLI).

## 48. Sensitivity Analysis

**(TARGET)** What changes if the assumptions in section 47 are wrong:

| Assumption | 10x case | What breaks first |
|---|---|---|
| Engineers: 500 -> 5,000 | 10x commit volume | concurrent CI jobs ~80, still fine for a modest runner fleet; fingerprint-bucket lookup stays O(1), unaffected |
| Failure rate: 10% -> 25% | 2.5x failure events | agent-run volume crosses into needing the backpressure/dedup design in section 49 sooner than expected |
| Agent duration: 2min -> 10min | 5x concurrency per agent run | the "effectively always <1 concurrent" comfort in section 47 disappears; a bounded worker pool becomes load-bearing, not optional |
| Artifact size: 500MB -> 2GB | 4x storage | 10.5TB rolling becomes ~42TB; tiered retention (hot/cold, same instinct as any storage-lifecycle design) becomes necessary, not a nice-to-have |

The exercise matters more than any single number: know which assumption, if wrong, changes which architecture decision, and say so unprompted.

## 49. AI-Specific Backpressure

**(TARGET)** A failure storm without correlation is an agent storm: 10,000 test failures from one bad dependency release naively becomes 10,000 independent LLM investigations. With fingerprinting (MEASURED: `FailureFingerprint` is designed exactly for this - same normalized signature, same 16-hex digest regardless of which of the 10,000 runs produced it) that collapses to however many genuinely distinct fingerprints exist, often a handful.

```
10,000 raw failures -> fingerprint -> ~18 unique fingerprints -> 18 investigations
```

Additional controls at scale: per-repository and global concurrency limits, per-fingerprint locks (one investigation in flight per fingerprint, not N racing to reach the same conclusion), token budgets, priority queues by severity, load shedding, and circuit breakers on the LLM provider itself.

## 50. Agent Scheduling

**(TARGET)** Separate worker pools by priority so low-value work never starves high-value work:

```
HIGH:   production/release-blocking failures
NORMAL: main-branch CI failures
LOW:    flake investigation, historical analysis, documentation generation
```

A backlog of flake-scoring work should never delay triage of a release-blocking regression. This is a bulkhead pattern (section 188 territory in the sibling privacy/security document, referenced here because it's the same idea): isolate concurrency pools per class of work so one noisy class can't consume the shared budget.

## 51. AI Cost Architecture

**(TARGET)** A model router that only pays for reasoning where reasoning is warranted, extending the rules-first pattern already proven at the classification layer (MEASURED: `RuleClassifier` handles the common case sub-millisecond with zero network calls; `ClaudeClassifier` only runs below 0.60 confidence):

```
FailureEvent -> known fingerprint? --yes--> reuse historical resolution, $0
             --no--> lightweight classifier -> ambiguous? --no--> small model
                                              --yes--> reasoning model (Claude)
```

Track tokens/failure, cost/failure, cost/resolved-failure, cache-hit rate, and historical-resolution reuse rate. `PatchGenerator`'s truncation to the first-and-last portions of a file/log (MEASURED: `maxFileChars = 6_000` in `PatchGenerator`, `maxLogChars = 4_000` in `ClaudeClassifier`) and its use of Anthropic's ephemeral prompt cache on the system prompt (MEASURED: `cache_control: ephemeral` in both classifiers' request bodies) are already real, working instances of this cost discipline, not aspirational.

## 52. Data Model at System-Design Depth

**(TARGET)** Proposed schema, not implemented:

```
repositories(id, name, owner_team)
ci_runs(id, repo_id, commit_sha, started_at, status)
failures(id, ci_run_id, category, confidence, summary)
failure_fingerprints(fingerprint PK, category, normalized_signature, first_seen_at)
failure_occurrences(id, fingerprint FK, failure_id FK, occurred_at)
agent_runs(id, failure_id FK, model, started_at, ended_at, outcome)
tool_calls(id, agent_run_id FK, tool_name, args_hash, result_summary, timestamp)
remediation_attempts(id, fingerprint FK, agent_run_id FK, attempt_number, state)
patches(id, remediation_attempt_id FK, file_path, unified_diff, confidence)
pull_requests(id, remediation_attempt_id FK, github_pr_number, state)
deployments(id, pull_request_id FK, artifact_digest, environment, state)
deployment_leases(service_id, environment, lease_id, fencing_token, owner, expires_at)
human_reviews(id, pull_request_id FK, reviewer, decision, comment)
```

`remediation_attempts.state` is the persisted form of the state machine in section 37. `failure_fingerprints.fingerprint` is exactly the `FailureFingerprint.value` string produced today (MEASURED). Structured relational storage for everything above; object storage for raw artifacts/logs referenced by ID, not embedded in rows; a vector index (if adopted at all) sits beside this as a secondary lookup that always resolves back to a `failure_occurrences` row, never as the source of truth.

## 53. API Design at System-Design Depth

**(TARGET)**

```
POST /v1/failures                          -- ingest a FailureEvent
GET  /v1/fingerprints/{fp}/history          -- prior occurrences + resolutions
POST /v1/remediations                       -- Idempotency-Key: fingerprint+sha
GET  /v1/remediations/{id}
POST /v1/remediations/{id}/approve
POST /v1/remediations/{id}/reject
POST /v1/deployments
POST /v1/deployments/{id}/rollback
GET  /v1/services/{id}/health
```

Every mutating endpoint takes an idempotency key (section 43). Pagination on every list endpoint. Errors return an actionable body, not a bare status code (section 176/`API Ergonomics` pattern, same document): `409 DeploymentConflict - deployment for checkout/prod is owned by d-381; retry after it completes or cancel it explicitly`, not a bare `409`.

## 54. MCP Contracts at Implementation Depth

**(TARGET, extends Part A's agent-tooling sections)** Every tool exposed to a model needs a stated contract, not just a name:

```
github.get_file(repo, ref, path)          permission: READ,  idempotent: yes
github.create_draft_pr(repo, base, ...)   permission: WRITE, idempotent: no, human_approval: required
xctriage.fingerprint(failure)             permission: READ,  idempotent: yes
sandbox.validate(proposal, repo_root)     permission: WRITE (ephemeral only), audit: required
```

Every field on this contract table maps to something `SandboxValidator` and `RemediationPolicy` already encode structurally today (MEASURED) even without a formal MCP contract wrapper: `SandboxValidator.validate` never mutates `repoRoot` itself, only an ephemeral worktree; `RemediationPolicy` methods are pure, read-only decision functions with no side effects. The contract table is documentation of a boundary that already exists in the type signatures, not a new boundary being invented.

## 55. Service-by-Service Trade-Off Analysis

**(TARGET)**

| Decision | Alternative | What it improves | What it costs | Verdict for xctriage's scale |
|---|---|---|---|---|
| Event bus: none yet | Kafka | replay, ordering, decoupling | operational weight, another stateful system to run | not justified until event volume or replay is a measured need |
| Workflow: plain state machine table (section 52) | Temporal | built-in retries, visibility, long-running workflow primitives | new runtime dependency, new failure mode to reason about | plain table is sufficient while workflows are short (minutes, not days) |
| DB: Postgres | DynamoDB | operationally simpler at very high write scale | loses relational joins the data model in section 52 depends on | Postgres wins; the schema is fundamentally relational |
| GitOps: Argo CD | Flux | more mature UI/rollout primitives (Argo Rollouts) | GitOps is GitOps either way | Argo CD, mainly for Argo Rollouts' canary primitives (section 39) |

## 56. Explicit SPOF Walk

**(TARGET)** For each component: what happens if it dies right now.

| Component | Impact if it dies | Recovery |
|---|---|---|
| Event bus (if adopted) | new failures stop being ingested | consumers resume from last committed offset once it's back |
| Postgres | writes stall; deployment state machine can't advance | failover replica, or a bounded outage window |
| GitOps reconciler | no new deploys apply, but running services are unaffected | reconciler restart catches up from Git state, no data lost |
| LLM provider | no new remediation proposals | **deterministic xctriage parsing/fingerprinting must keep working regardless** - this is a hard invariant, not a nice-to-have |
| GitHub | analysis can continue; code mutation (PRs) pauses | queued PR creation retries with backoff once it's back |

The load-bearing invariant across the whole design: **AI being unavailable must never prevent deterministic CI/test analysis.** This is already true today (MEASURED): `xctriage analyze` with no `--llm` flag never touches the network at all; `RuleClassifier` has zero dependency on `ClaudeClassifier`.

## 57. Disaster Recovery

**(TARGET)** RPO/RTO targets, not measured production numbers:

| Data class | RPO target | RTO target |
|---|---|---|
| Failure DB | < 5 min | < 30 min |
| Agent transcripts | < 1 hr | < 4 hr |
| Deployment state | ~0 | < 5 min |

Backups: point-in-time recovery on Postgres, object-storage versioning for artifacts, Git itself as the recovery mechanism for desired state (it's already durable and versioned by construction). None of this exists today; xctriage's real persistence is a single local SQLite file (MEASURED: `FlakyTestTracker`, `~/.xctriage/flaky.db`, WAL mode) with no backup story at all, which is a fine tradeoff for a single-user local tool and a real gap the moment it's shared across a team.

## 58. Multi-Region Architecture

**(TARGET)** Start with the simplest defensible shape: an active control region plus a warm standby, not active-active. Active-active on the deployment-control-plane state (leases, desired-state writes) creates exactly the kind of "who's authoritative" consistency problem that PC/EC (section 46) says to avoid. Separate **application traffic failover** (the services xctriage might eventually help deploy) from **deployment-control-plane failover** (xctriage/CD's own availability) - they are different problems with different consistency requirements, and conflating them is a common design-review trap.

## 59. Supply-Chain Security

**(TARGET)**

```
source -> SAST -> dependency scan -> build -> SBOM -> container scan
   -> sign artifact -> store -> admission verifies signature -> deploy
```

MEASURED today: the real CI pipelines already run SAST (CodeQL in GitHub Actions, Semgrep in Jenkins since CodeQL needs a GHAS license to self-host) and a dependency/secret/misconfig scan (Trivy), per the project's own README. Not yet built: SBOM generation, artifact signing (Cosign/Sigstore), and admission-time signature verification. These slot in after the existing scan stage without changing anything upstream of it.

## 60. AI Patch Supply-Chain Provenance

**(TARGET)** A model-authored diff needs the same provenance discipline as any other artifact, recorded as internal audit metadata, never as a commit message, code comment, or PR attribution badge:

```
agent_run_id, model, model_version, failure_id, fingerprint,
policy_version_evaluated, tool_calls, retrieved_files,
generated_diff_hash, validation_result (SandboxValidator.Result, MEASURED shape),
human_approver, deployment_id, verification_result
```

This is a natural extension of what already exists structurally: `PatchProposal` (MEASURED: `filePath`, `unifiedDiff`, `rationale`, `confidence`) plus `SandboxValidator.Result` (MEASURED: `applied`, `buildSucceeded`, `testSucceeded`, `output`) already carry most of the fields a provenance record needs; the target design is persisting them, not inventing them.

## 61. Observability Architecture

**(TARGET)** Metrics, logs, traces, plus workflow-level events, correlated by `fingerprint`, `agent_run_id`, `remediation_id`, `deployment_id`, and `trace_id`. A single failure should be traceable end to end: CI -> xctriage -> event bus -> orchestrator -> LLM -> sandbox -> GitHub -> CD -> production -> verification. None of this instrumentation exists today (MEASURED: xctriage emits terminal/JSON/Slack reports, no metrics endpoint, no tracing).

## 62. Grafana Dashboards

**(TARGET)** Separate dashboards, not one overloaded board:

- **xctriage overview**: failures/hour, unique fingerprints, duplicate-suppression rate, flake rate, top failing suites
- **agent reliability**: triage success rate, tool error rate, timeout rate, patch acceptance rate
- **remediation**: patches generated, PRs opened/merged, false-remediation rate
- **continuous deployment**: deploy frequency, rollback rate, canary failure rate
- **cost**: tokens, LLM spend, cost/failure, cost/resolution

None of this is instrumented today. `FlakyTestTracker`'s scoring query (MEASURED: `score = failures-in-window / total-builds-in-window`, 90-day window) is the one piece of the codebase that already computes a dashboard-shaped aggregate - it just renders to a terminal bar chart (`xctriage flaky`) instead of Grafana today.

## 63. DORA Metrics

**(TARGET)** Deployment frequency, lead time for changes, change failure rate, MTTR. How xctriage's pieces could eventually move each, framed as hypotheses to validate, not results already achieved:

- automated triage -> lower lead time (hypothesis: less time spent finding root cause)
- sandbox-validated remediation -> lower change failure rate (hypothesis: bad patches get caught before merge, not after)
- canary + SLO gates -> lower MTTR (hypothesis: automatic rollback beats a paged human diagnosing manually)

Instrument first, claim improvement only once there's a before/after measurement. This mirrors the honest posture already established for xctriage itself in Part A of the project Q&A: no fabricated percentage improvements for a system with no production traffic.

## 64. SRE Error Budgets

**(TARGET)**

```
Service SLO = 99.9% -> monthly error budget ~= 43.8 minutes
```

Deployment policy tightens as the budget depletes: healthy budget -> normal canary automation; 50% consumed -> slower rollout stages; 80% consumed -> require human approval even for previously-auto-approved changes; budget exhausted -> deployment freeze except explicitly-approved emergency fixes. **A deterministic policy engine reads the budget and adjusts the gate - the LLM never sees or reasons about the budget.**

## 65. SLO-Based Deployment Gates

**(TARGET)** Never gate on a bare HTTP 200. A real gate composes multiple signals:

```
error_rate < threshold AND p99_latency < threshold
  AND availability > threshold AND no crash-rate regression
  AND fingerprint from the original failure does not recur
```

That last clause is the one unique to an AI-remediation deploy specifically: a canary that looks healthy on generic SLOs but where the *original bug* silently reappears (e.g. the fix regressed under a traffic pattern the sandbox test didn't exercise) should still fail the gate. This is why fingerprint-recurrence checking belongs in the post-deploy verification step, not just the pre-merge sandbox step.

## 66. Chaos Engineering

**(TARGET)** Inject failure into the platform itself and state the expected behavior for each:

| Fault | Expected behavior |
|---|---|
| LLM timeout | remediation queues/retries; deterministic triage unaffected |
| LLM returns malformed JSON | rejected by schema parsing, same as `PatchGenerator.parse` already does today (MEASURED: throws `TriageError.parseError` on unparseable or missing-field JSON) |
| GitHub 500 | workflow retries with backoff, no duplicate PR on eventual success (idempotency key, section 43) |
| Kafka duplicate delivery (if adopted) | consumer is idempotent by construction, no double-processing |
| Argo CD unavailable | running deployments unaffected; new deploys queue until it recovers |
| Sandbox worktree creation fails | `SandboxValidator` already returns a typed failure result rather than crashing (MEASURED: `applied: false` result, tested in `SandboxValidatorTests.test_validate_stopsAtWorktreeFailureWithoutApplyingOrBuilding`) |

## 67. Game Days

**(TARGET)** Two example scenarios, written in the format a real game-day runbook would use:

**Game Day 1 - LLM provider unavailable.** Expected: xctriage parsing, fingerprinting, and rule classification keep working (MEASURED: none of these have any dependency on `ClaudeClassifier`); AI triage and remediation queue or fail closed; no unsafe fallback behavior (never silently apply an unvalidated patch because the model timed out mid-request).

**Game Day 2 - GitHub unavailable during remediation.** Expected: workflow enters a `WAITING_FOR_GITHUB` state, retries with exponential backoff, and does not create a duplicate PR once GitHub recovers (idempotency key on fingerprint + commit SHA prevents the double-create).

## 68. Incident Runbooks

**(MEASURED)** `docs/runbooks/` exists with five runbooks, each following the same five-question structure: what happened, how do I know, what's the blast radius, what happens automatically, what does a human do, how do I verify recovery. All five document real failure modes of the actual code, not proposed future ones:

```
docs/runbooks/
  github-rate-limit.md        gh CLI hitting GitHub's rate limit during --create-pr
  llm-provider-outage.md      api.anthropic.com unreachable (PatchGenerator/ClaudeClassifier)
  duplicate-pr.md             what to check if IdempotencyStore's guarantee appears to have failed
  sandbox-hang.md             a hung swift build/test - see the SandboxValidator timeout it drove
  sqlite-lock-contention.md   concurrent writers to the same FlakyTestTracker/state/idempotency db
```

`sandbox-hang.md` is the concrete example of this process working as intended: writing that
runbook surfaced a real, then-unfixed gap (`SandboxValidator` had no timeout, so a hung
`swift build` would hang the CLI forever), which was then closed with an actual `timeout`
parameter, a `withTaskCancellationHandler`-based process kill, and a test proving a 30-second
hang gets killed inside 1 second at a 0.3s configured timeout. The runbook was updated afterward
to describe the fix, not just the gap.

## 69. Architecture Decision Records

**(MEASURED)** `docs/adr/` exists with 8 ADRs, each with Context / Decision / Alternatives / Why Chosen / Consequences / When to Revisit, all documenting decisions already real and already built:

```
ADR-001-sqlite-for-local-durable-state.md
ADR-002-deterministic-policy-outside-the-llm.md
ADR-003-draft-only-prs-no-autonomous-merge.md
ADR-004-sandbox-validation-in-a-disposable-worktree.md
ADR-005-durable-remediation-state-machine.md
ADR-006-idempotency-via-sqlite-unique-constraint.md
ADR-007-no-implemented-continuous-deployment.md
ADR-008-single-file-narrow-autonomy-scope.md
```

ADR-007 is the one that matters most for reading the rest of this document set correctly: it's
the explicit statement that GitOps/Kubernetes/Terraform/Kafka/multi-region — everything section
34 onward in this file describes — is target design, not running infrastructure, and states why
this repo deliberately contains no stub/fake clients pretending otherwise.

## 70. Repository Documentation Should Work at Three Levels

**(TARGET)** Every major concept gets a 30-second explanation, a 5-minute explanation, and a deep dive. Example, `FailureFingerprint`:

- **30 seconds:** "Turns noisy variants of the same failure into one stable ID."
- **5 minutes:** category + filename + test name + normalized error message, SHA256'd, truncated to 16 hex characters; volatile tokens (UUIDs, addresses, temp paths) stripped before hashing so re-runs of the same bug match.
- **Deep dive:** collision math at 64 bits (section 47 of Part A's project Q&A already covers this concretely, MEASURED numbers included), why false grouping is worse than false separation, why `Hasher` was rejected in favor of SHA256.

## 71. README Visual Storytelling

**(TARGET)** The README's first screen should communicate the whole product in about 10 seconds via one hero diagram, then progressively reveal detail below it. Proposed hero flow (not yet in the real README, which currently documents the parse/classify/track pipeline only, MEASURED):

```
test fails -> xctriage -> AI investigation -> sandbox-validated patch
  -> human-approved PR -> canary deployment -> verification
```

## 72. SVG Architecture Diagrams

**(TARGET)** Proposed assets under `docs/assets/`, none of which exist yet beyond the real `docs/assets/logo.svg` and `docs/assets/demo.gif` referenced in the current README (MEASURED):

```
docs/assets/
  remediation-state-machine.svg   (section 37's state machine, rendered)
  ci-cd-separation.svg            (section 35)
  canary-rollout.svg              (section 39)
  trust-boundary.svg              (section 88)
  spof-walk.svg                   (section 56)
```

Consistent visual language: blue = deterministic platform, purple = AI reasoning, green = validated/safe action, orange = human approval, red = failure/rollback, cylinders = persistent stores, diamonds = actual branch points only.

## 73. SVG Diagram Design Rules

**(TARGET)** No decorative box without architectural meaning. Diamonds only for real decision points (e.g. `RemediationPolicy`'s allowed/denied branch, MEASURED as a real `enum Decision` in the code, not an invented example). Read paths and write paths visually distinguishable. Human-approval steps visually obvious, never blended into an automated flow. Production write capability, when it exists, must be visually unmistakable - this is the diagram-level version of the "no direct LLM-to-production path" invariant that runs through the whole design.

## 74. Animated GIFs for README

**(TARGET)** The real repo already has one demo GIF (MEASURED: `docs/assets/demo.gif`, referenced in the current README, generated via `scripts/make_demo.sh`). Proposed additions, none built: a remediation GIF (failure -> sandbox validation -> proposed diff), and a continuous-deployment GIF (merge -> canary stages -> verification) once that layer exists. Keep it to short, technical demonstrations, not marketing animation.

## 75. Prefer Reproducible GIF Generation

**(TARGET)** The real repo already does this for its one existing demo (MEASURED: `scripts/make_demo.sh`, referenced in the README's Tests section: `bash scripts/make_demo.sh # run demo fixtures`). Any new GIF should extend that same script-driven pattern rather than being hand-recorded and hand-edited, so documentation assets stay regenerable as the CLI's actual output format changes.

## 76. Terminal Demo

**(TARGET, partially MEASURED)** The real README already shows a real `xctriage analyze` terminal transcript (MEASURED, copied verbatim from the actual README):

```
$ xctriage analyze xcbuild.log --source xcodebuild --build-id ios27-5512
  ✗  COMPILATION ERROR
  CONFIDENCE  ██████████████████░░ 92%
  ...
```

Proposed addition, not yet real: an equivalent transcript for `xctriage remediate`, showing the fingerprint, category, sandbox result, and rationale lines the real CLI now prints (MEASURED: this exact header format exists in `Sources/xctriage/main.swift`'s `Remediate.run()` today) but is not yet captured as a polished README transcript.

## 77. Demo Environment

**(TARGET)** A reproducible example repo with a deliberately broken test, driven by `make` targets:

```
examples/checkout-service/
make demo-failure       -- introduce the deterministic bug
make demo-triage        -- xctriage analyze
make demo-remediation   -- xctriage remediate
```

Does not exist today. This is more convincing than a screenshot because anyone can clone and reproduce it, but it's explicitly listed here as not-yet-built.

## 78. Local Developer Experience

**(TARGET)** Target onboarding: `git clone && swift build -c release` (MEASURED: this already works today, per the real README's "Build from source" section) plus a proposed `make bootstrap` wrapper and mock implementations of GitHub/Jira/PagerDuty/LLM for testing the target agent/CD layers without real credentials.

## 79. Makefile / Task Runner

**(TARGET)** No Makefile exists in the repo today (MEASURED: the real workflow is `swift build`, `swift test`, `swift build -c release`, directly). Proposed target list:

```
make build   make test   make lint   make security
make demo    make docs   make diagrams   make clean
```

## 80. CI for xctriage Itself

**(MEASURED, mostly real)** The repo already dogfoods itself: both the Jenkinsfile and `.github/workflows/ci.yml` run `swift build`, `swift test`, lint (SwiftLint), SAST (Semgrep/CodeQL), and a Trivy scan, then classify their own test failures with xctriage and apply the single documented auto-remediation rule (flaky-test retry at >=0.75 confidence, capped at one retry, MEASURED from the real README). "xctriage uses xctriage to triage xctriage" is a real, already-shipped property of this repo, not a target.

## 81. Documentation Architecture

**(TARGET)** Proposed `docs/` layout, none of it built beyond the real `docs/assets/` directory (MEASURED):

```
docs/
  00-overview.md   01-architecture.md   09-continuous-deployment.md
  12-security.md   14-capacity.md       18-threat-model.md
  adr/   runbooks/   assets/
```

## 82. README Structure

**(TARGET)** Proposed shape: one-sentence pitch, hero SVG, a short GIF, "why xctriage" (traditional flow vs xctriage flow), architecture diagram, safety model, quick start, link out to `docs/` for depth. The real README today (MEASURED) already has most of this shape for the parsing/classification/tracking layer specifically (architecture diagram, CI sources table, failure categories table, Swift 6 concepts section, install/usage) - the target work is extending the same structure to cover remediation and the proposed CD layer, not restructuring what exists.

## 83. "Traditional vs xctriage" Visualization

**(TARGET)**

```
Traditional                          xctriage (target, full loop)
test fails                           test fails
  -> Slack/PagerDuty page              -> fingerprint + correlate history
  -> search CI logs                    -> investigate automatically
  -> search Git/Jira                   -> reproduce
  -> try to reproduce                  -> generate candidate patch
  -> write a fix                       -> sandbox-validate (real today)
  -> wait for CI                       -> human-reviewed PR
  -> deploy                            -> progressive deployment (target)
  -> watch dashboards                  -> automatic verification (target)
```

## 84. Explain Complex Concepts Simply

**(TARGET)** Every doc page: in one sentence, why this exists, how it works, what can go wrong, how failure is handled, deep dive. Example already drafted at full depth in Part A's project Q&A for `FailureFingerprint` and `RemediationPolicy` (MEASURED content, just not yet reformatted into this five-part template).

## 85. "Explain Like I'm New to DevOps" Callouts

**(TARGET)** Short inline callouts at points where the "why" isn't obvious from the diagram alone:

> Why fingerprint before triage? Without it, 500 identical failures from one bad commit trigger 500 separate investigations. With it: 500 failures -> 1 fingerprint -> 1 investigation.

> Why pull-based GitOps instead of push? If CI holds production credentials, compromising CI compromises production. With GitOps, the cluster pulls its own desired state; CI never gets a production credential at all.

## 86. Sequence Diagrams

**(TARGET)** Proposed sequence diagrams for flows arrows alone can't explain: Test Failure -> CI -> xctriage -> Orchestrator -> LLM -> GitHub (Part A's investigation flow, MEASURED as real code for the classify step, TARGET for the rest); Remediation -> GitHub MCP -> Sandbox -> Validator -> Reviewer -> Human (the sandbox half is real today, MEASURED); Deployment -> Artifact Store -> GitOps Repo -> Argo CD -> Rollouts -> Prometheus -> Policy Engine (entirely TARGET).

## 87. State-Machine Diagram

**(TARGET)** A dedicated large diagram for the remediation lifecycle in section 37, with distinct visual paths for success, human intervention, policy rejection, validation failure, deployment failure, and rollback - and an explicit, visually obvious absence of any arrow from "LLM" directly to "production."

## 88. Trust-Boundary Diagram

**(TARGET)**

```
UNTRUSTED (test logs, repo contents, issues, PR comments, external text)
  -> sanitization / policy boundary
  -> LLM
  -> tool policy gate
  -> READ tools | WRITE tools
  -> human approval
  -> production
```

The "tool policy gate" box is `RemediationPolicy`'s two methods today (MEASURED), drawn as the boundary they already structurally are.

## 89. Agent Trace Visualization

**(TARGET)** A timeline view for one remediation run, once real telemetry exists to drive it:

```
00:00 failure detected      00:02 fingerprint generated
00:08 historical match search   00:19 root-cause hypothesis
00:37 reproduction confirmed    01:03 patch generated
01:42 sandbox build+test passed 02:12 draft PR created
```

No real telemetry exists yet to populate this (MEASURED: no timing instrumentation in the current codebase beyond the CLI's own `durationMS` field on `TriageReport`).

## 90. Failure Memory Visualization

**(TARGET)**

```
                 Jira 4812
                 |
Failure 91d7 --- Incident PD-129
                 |
                 PR #913 -> Commit 7ac9f42
                 |
                 similar failure, 6 months ago
```

Communicates the knowledge-graph idea (section 52's data model) without requiring the reader to understand embeddings or vector search first.

## 91. Continuous Deployment GIF

**(TARGET)** Two proposed GIFs once the CD layer exists: one showing a full successful canary (5% -> 25% -> 50% -> 100%), one showing an intentional failure at 25% and the automatic rollback described in section 40. Neither can be built until the underlying CD layer is real.

## 92. DORA Dashboard Example

**(TARGET)** A sample dashboard image with clearly labeled **simulated/demo data**, never presented as production history. Given xctriage has no production deployment history (MEASURED), any DORA numbers shown before real data exists must be labeled as such, unambiguously, in the image itself.

## 93. Benchmark Suite

**(TARGET)** Proposed `fixtures/failures/` covering assertion failure, crash, timeout, flake, dependency regression, config regression, infra failure, simulator failure, network failure, known historical regression. Evaluate classification accuracy, fingerprint accuracy, retrieval recall, patch validation rate against this fixture set. Does not exist today; the real test suite (MEASURED, 104 tests) covers unit-level correctness of each component, not end-to-end classification accuracy against a labeled corpus.

## 94. Load Testing

**(TARGET)** Proposed: `xctriage load-test --failures 100000 --unique-fingerprints 500 --duration 10m`, measuring ingestion throughput, fingerprint latency, queue depth, dedup ratio. No load-testing rig exists today; nothing in xctriage has been run at any volume beyond a single developer's local test suite.

## 95. Performance Profiles

**(TARGET)** Proposed profiling across small/medium/large `.xcresult` bundles, measuring parse time, memory, and fingerprinting time specifically. (MEASURED, real numbers from this session, not a formal profile: full local `swift test` run of 104 tests completes in ~1.6-2s including all classifier, fingerprint, policy, patch-generation, and sandbox-orchestration tests combined - this is a dev-loop signal, not a production performance profile of `.xcresult` parsing at scale.)

## 96. Deployment Modes

**(TARGET)** Local developer -> single-node demo -> Docker Compose -> Kubernetes development -> production Kubernetes -> enterprise multi-cluster. Today xctriage only exists in the first mode (MEASURED: a locally-built CLI binary run directly, or invoked from within a Jenkins/GitHub Actions job). Every mode past that is proposed.

## 97. Infrastructure as Code

**(TARGET)** Proposed `infra/terraform/` with modules for network, Kubernetes, Postgres, observability, and secrets, plus environment overlays (dev/stage/prod), remote state, plan-on-PR, and drift detection. None of this exists; xctriage today has no infrastructure of its own to provision (MEASURED: it's a CLI binary and two CI pipeline definitions, nothing that runs as a service).

## 98. Platform Engineering / Golden Path

**(TARGET)** A team should onboard by writing a small declarative config, not by understanding the whole system:

```yaml
xctriage:
  project: checkout
  tests: { path: CheckoutTests }
  owner: payments-platform
  remediation: { enabled: true, max_risk: low }
  deployment: { strategy: canary }
```

The platform absorbs the complexity centrally so application teams get a simple interface, the same instinct behind any well-run internal platform team: centralize the hard parts once, expose a small typed config surface, and let teams opt in without needing to understand the machinery underneath.

## 99. Policy as Code

**(TARGET)** Safety policy belongs in versioned, testable code, not buried in a prompt - which is exactly the design choice `RemediationPolicy` already makes today (MEASURED: a plain Swift struct, unit tested, not a system-prompt instruction). At larger scale this would likely become OPA/Rego evaluated deterministically outside the model, with rules like "deny auto-remediation if a security-sensitive path changed, more than 5 files are touched, or a migration is detected" - a direct extension of `forbiddenPathPrefixes` and `maxFilesChanged`, both real today.

## 100. Golden Signals for the Platform Itself

**(TARGET)** Latency, traffic, errors, saturation for: failure ingestion, agent workers, Postgres, the sandbox fleet, GitHub API calls, and the deployment controller. None instrumented today; AI-specific metrics (section 51, 63) should complement this, not replace it - a platform that only measures "is the AI working" and not "is the platform working" has an observability gap at the wrong layer.

## 101. Burn-Rate Alerting

**(TARGET)** Multi-window burn-rate alerts instead of a single static threshold: page when the error budget (section 64) is being consumed fast enough to threaten the SLO within the alerting window, not merely because one request was slow. Not implemented; no SLO or error budget is tracked for anything in xctriage today.

## 102. PagerDuty Architecture

**(TARGET)** An escalation hierarchy so PagerDuty doesn't page for every failed test:

```
single failure                -> xctriage only, no page
repeated known fingerprint     -> Jira update
release-blocking failure       -> Slack/Jira
critical production regression -> PagerDuty, deduped on fingerprint
infra-wide correlated failure   -> one shared incident, not N
```

## 103. Jira Lifecycle

**(TARGET)** `OPEN -> TRIAGING -> ROOT_CAUSE_IDENTIFIED -> PATCH_PROPOSED -> PR_OPEN -> VALIDATING -> DEPLOYING -> VERIFYING -> RESOLVED`, keyed by fingerprint so the same recurring failure updates one ticket instead of spawning a new one every occurrence.

## 104. GitHub PR Quality

**(TARGET)** A machine-generated PR should read like a serious engineering PR: Summary, Failure, Root Cause, Evidence, Change, Why This Works, Validation, Risk, Rollback, Related Incident/Jira. Concise evidence and a decision, never a chain-of-thought dump. `PatchProposal.rationale` (MEASURED: one sentence, real field in the codebase today) is the seed of the "Why This Works" section; `SandboxValidator.Result` (MEASURED) is the seed of "Validation" - both already exist as structured data, just not yet rendered into a PR body template.

## 105. Human Override

**(TARGET)** Every automated action needs a PAUSE / CANCEL / REJECT / ROLLBACK / DISABLE_AUTONOMY control, wired into the state machine from section 37 so an override is a state transition, not an out-of-band hack.

## 106. Kill Switch

**(TARGET)** A global emergency flag set: `AI_WRITES=false`, `PR_CREATION=false`, `AUTO_DEPLOY=false`, `AUTO_MERGE=false`. Deterministic xctriage parsing must keep working regardless (same invariant as section 56/66). Nothing like this exists today because there is no write-capable automation yet to kill - `remediate` only ever prints or writes a diff file locally (MEASURED), it never touches GitHub, Jira, or a cluster.

## 107. Failure Modes and Effects Analysis

**(TARGET)**

| Failure | Detection | Automatic mitigation | Human action |
|---|---|---|---|
| LLM hallucinated file path | `PatchGenerator.parse` requires `file_path`/`unified_diff` fields present (MEASURED) | rejected at parse | none needed |
| Diff touches forbidden path | `RemediationPolicy.isPatchAllowed` (MEASURED) | rejected before surfacing | none needed |
| Sandbox build fails | `SandboxValidator` (MEASURED) | rejected, worktree cleaned up | review sandbox output |
| Wrong correlation groups two real bugs together | none today (correlation beyond exact fingerprint match doesn't exist yet) | -- | manual split, target work |

## 108. "10x Scale" Section

**(TARGET)** At 10x repos/builds/failures, the first thing to bottleneck is the sandbox step (section 47/48) - it's a real `swift build`, and that doesn't get 10x cheaper just because more failures are arriving. The two policy gates already existing ahead of it (MEASURED) are exactly the right shape of mitigation: reject 95% of ineligible attempts for free before ever paying for a build.

## 109. "100x Scale" Thought Experiment

**(TARGET)** At 100x, Postgres sharding or read replicas for the failure-history tables, regional agent workers to keep LLM round-trip latency down, and a dedicated semantic-retrieval service separated from the primary relational store all become plausible. None of this is a near-term implementation target; it's a "here's the direction, not the current plan" answer for a design-review follow-up.

## 110. Simplicity Is a Requirement

**(TARGET/philosophy)** For every component in this document: what problem does it solve today? If the honest answer is weak, it doesn't belong in the MVP.

### What I Deliberately Did Not Build

```
No event bus (Kafka/SQS) - no measured event volume or replay requirement yet.
No Kubernetes - nothing in xctriage runs as a long-lived service yet.
No Temporal - the remediation state machine (section 37) is short-lived
  enough that a plain persisted table is sufficient.
No multi-agent framework - one deterministic pipeline (parse -> classify
  -> fingerprint -> policy -> generate -> policy -> sandbox) plus one
  reasoning-model call is simpler and already fully built (MEASURED).
No vector database - exact fingerprint lookup (MEASURED, O(1) SHA256
  match) solves the "have I seen this before" question xctriage actually
  has today; semantic similarity is a target-scale addition, not a
  current gap.
```

## 111. Recommended MVP

**(TARGET, framed against what's actually built)** The MVP is not a redesign - it's what already exists today (MEASURED): parse -> fingerprint -> rule-classify -> optional LLM fallback -> two-gate remediation policy -> Claude-generated single-file patch -> sandbox validation -> printed/written proposal. The next honest MVP increment, in order: (1) a `draft PR` step that opens a real GitHub PR from a sandbox-validated proposal, gated by the same policy, requiring explicit human approval to merge - the smallest possible extension of what's already built; (2) then, only once that's proven, a deploy step. Mocking Jira/PagerDuty initially rather than building real integrations first is the right sequencing - the vertical slice (one failure, fully through to a verified fix) is more convincing than twenty shallow integrations.

## 112. Suggested Production-Oriented Repository Layout

**(TARGET)** Proposed evolution of the current flat `Sources/XCTriageKit/{Models,Classifiers,Parsers,Policy,Remediation,Reporters,Tracking}` layout (MEASURED, this is the real current structure) as the target system grows:

```
xctriage/                    (real today: Package.swift, Sources/, Tests/)
control-plane/                (target: api/, workflow/, policy/, persistence/)
agents/                       (target: triage/, investigator/, remediation/)
mcp/                          (target: github/, jira/, pagerduty/, ci/)
deployment/                   (target: gitops/, rollouts/)
observability/                (target: dashboards/, alerts/)
docs/                         (target: architecture/, adr/, runbooks/, assets/)
```

Stay a modular monolith until an operational boundary actually forces a service split - don't pre-split into microservices because the diagram has boxes for them.

## 113. Final Deliverable Style

This document optimizes for correctness, clarity, and honest labeling of what's real versus proposed over novelty or completeness-for-its-own-sake. Every MEASURED claim in this document traces back to a real file, a real test, or a real command run in this session; every TARGET claim is explicitly a proposal with no production evidence.

## 114. Final Principal-Level Review

**Staff DevOps Engineer - "what will make this painful to operate?"** Top concern: no observability yet (section 61) means the target CD layer would ship blind. Mitigation in the design: instrumentation is scoped as an early phase, not an afterthought (section 111's ordering). Gap: no current plan for who owns dashboard alert-fatigue tuning once it exists.

**SRE - "what fails at 2am?"** Top concern: the sandbox step's dependency on real `swift build`/`swift test` wall-clock time (section 47/108) is the single biggest latency and cost variable in the whole pipeline, and it's also the piece most likely to flake under host resource pressure. Mitigation: `SandboxValidator` already returns a structured, typed failure result rather than throwing an opaque error (MEASURED), so a 2am on-call engineer gets `applied/buildSucceeded/testSucceeded` booleans plus raw output, not a stack trace to reverse-engineer.

**Security Engineer - "how can the AI gain more authority than intended?"** Top concern: the two-gate policy (MEASURED) is the whole safety story today; if that pattern isn't extended with equal rigor to every new automated capability (PR creation, deploy triggering), the AI's effective authority grows faster than its audited authority. Mitigation: section 34's throughline states this explicitly - every new capability gets its own deterministic gate, never inherits trust from an existing one.

**Platform Engineer - "will teams actually adopt this?"** Top concern: today it's a single-user local CLI (MEASURED); nothing about multi-team config, ownership routing, or a golden path (section 98) exists yet. Gap acknowledged, not solved in this document.

**Principal Engineer - "which components are unnecessary?"** Answer: everything in section 110's "what I deliberately did not build" list (also `docs/architecture/WHAT_I_DID_NOT_BUILD.md`), kept out on purpose. The one component worth challenging hardest in this document is the proposed event bus (section 34/49) - worth deferring until failure volume is actually measured, not assumed.

### Architecture I'd Ship Today

Exactly what's real (MEASURED): the parse -> classify -> fingerprint -> two-gate policy -> propose -> sandbox-validate pipeline, as a local CLI, with no event bus, no deployment layer, no multi-tenant anything.

### Architecture I'd Grow Into

Sections 34-53 (CD, state machine, canary, rollback, data model, capacity) as the next real increment, in the MVP order given in section 111, adding Temporal/Kafka/a dedicated retrieval service only if a measured requirement (not a diagram aesthetic) demands them.

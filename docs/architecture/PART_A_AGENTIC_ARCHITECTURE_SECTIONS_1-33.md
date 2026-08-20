# Target Agentic Architecture (Sections 1-33)

This document is a target-architecture design review: what xctriage's
agentic and auto-remediation layer could grow into, not a description of
infrastructure that exists today. See the repo root `README.md` for what
is actually built and tested right now (`BuildLogParser`/`XCResultParser`,
a 19-rule `RuleClassifier` across 8 categories, a `ClaudeClassifier`
fallback, a `FlakyTestTracker`, `FailureFingerprint`, a two-gate
`RemediationPolicy`, `PatchGenerator`, `SandboxValidator`, and the
`remediate` CLI subcommand wiring all of it together, with 76 passing
tests). Everything below is the system this project could grow into on top
of that real core.

Every concrete number or capability below is tagged (MEASURED), (TARGET),
or (SIMULATED). (MEASURED) means it is true of the repo today. (TARGET)
means it is a proposed design goal with no real measurement behind it yet.
(SIMULATED) means an illustrative worked example constructed to make the
math concrete, not a real observation. Nothing here should be read as if
it already runs: the honest framing is "here is how this could be built,"
not "here is what is built."

---

## 1. Core End-to-End Workflow

The (MEASURED) core already does steps 1-4 of this list for the read-only
path, and steps 5, 10, 11, 14 for the remediation path. Steps 6-9, 12, 13,
15-18 are (TARGET) - they require an orchestration layer that does not
exist in the repo today.

1. A Swift/iOS/macOS test suite executes in CI. (MEASURED: xctriage already
   ingests xcodebuild output and `.xcresult` bundles from any CI that can
   shell out to a binary.)
2. xctriage parses `.xcresult` bundles, logs, stack traces, and test
   metadata into a normalized `FailureEvent`-shaped result. (MEASURED, via
   `BuildLogParser` and `XCResultParser`.)
3. xctriage generates a deterministic fingerprint. (MEASURED, via
   `FailureFingerprint` - SHA256 over category + file + test + normalized
   message, truncated to 16 hex chars.)
4. The platform classifies the failure into one of 8 categories. (MEASURED,
   via `RuleClassifier`, with `ClaudeClassifier` as a confidence-gated
   fallback.)
5. Failures are correlated against fingerprint history to suppress
   duplicate remediation attempts. (PARTIAL/MEASURED: `FlakyTestTracker`
   does this for flake scoring; a general failure-history correlation store
   is TARGET, see Section 7.)
6. Critical failures generate or update a PagerDuty incident. (TARGET - no
   PagerDuty integration exists; today the ceiling is a Slack webhook via
   `SlackReporter`.)
7. An orchestration layer launches an AI triage workflow. (TARGET.)
8. Specialized agents gather context via approved tools. (TARGET - see
   Section 4 and the A2A subsection below.)
9. The system produces a root-cause hypothesis with confidence and
   evidence. (TARGET, though `ClaudeClassifier` already produces a
   `summary` + `suggestedFix` + `confidence` triple as a single-shot
   precursor to this.)
10. If policy permits, an implementation agent generates a candidate patch.
    (MEASURED, via `PatchGenerator` - one single-file unified diff.)
11. The patch is tested in an isolated sandbox. (MEASURED, via
    `SandboxValidator` - ephemeral `git worktree`, real `swift build` and
    `swift test --filter`.)
12. Static analysis, security scanning, and regression tests run against
    the patch. (PARTIAL: the sandbox already runs the specific failing
    test; running the *full* regression suite and SAST against every
    candidate is TARGET, gated by cost - see Section 19.)
13. A reviewer agent critiques the patch before a PR is opened. (TARGET.)
14. GitHub creates a pull request. (TARGET - the CLI today prints or writes
    the diff to a file; it does not call the GitHub API. This is the one
    piece explicitly deferred from the real build-out because opening a PR
    is a write to a shared system and deserves an explicit ask, not
    silent automation.)
15. Jira is created or updated with investigation state. (TARGET.)
16. Humans approve the PR unless the change is in an explicitly approved
    low-risk autonomous class. (TARGET for the workflow; the *principle*,
    the LLM proposes, deterministic code decides, is already enforced by
    `RemediationPolicy`'s two gates, MEASURED.)
17. Post-merge, the system watches subsequent CI runs to confirm the
    original fingerprint does not recur. (TARGET.)
18. The outcome becomes feedback for future triage decisions. (TARGET.)

The honest summary: the deterministic backbone (parse, classify,
fingerprint, propose, gate, sandbox-validate) is built and tested. The
agentic orchestration layer that would turn this into an autonomous
end-to-end loop is the design being reviewed in this document, not a
built system.

---

## 2. xctriage as the Foundational Intelligence Layer

xctriage's job in this target architecture is unchanged from what it does
today: be the deterministic source of truth that everything else - agents,
policy, dashboards - reads from. It should never become a thin wrapper
around an LLM call. Its responsibilities, extended from what's real:

```text
FailureEvent (TARGET schema, extends the real ClassificationResult/TriageReport)
├── event_id            (TARGET: UUID, not present today)
├── fingerprint          MEASURED - FailureFingerprint.value
├── timestamp            MEASURED - TriageReport.timestamp
├── repository            TARGET - not tracked; xctriage runs per-invocation, stateless of repo identity
├── branch / commit_sha   TARGET
├── build_id              MEASURED - Analyze.buildID, threaded through TriageReport
├── category               MEASURED - ClassificationResult.category
├── confidence              MEASURED - ClassificationResult.confidence
├── failure_sites            MEASURED - [FailureSite], file/line/column/testName/errorMessage
├── flake_score               MEASURED - FlakyTestTracker.scores(for:)
├── environment                TARGET - Xcode/SDK/simulator version not captured today
└── correlation_metadata        TARGET - cross-failure linkage, see Section 7
```

**Deterministic vs. AI-generated fields, stated explicitly:** fingerprint,
category (rule path), flake score, and all `FailureSite` fields are
deterministic - same input always produces the same output, no model
involved, unit-testable to an exact value. `category` (LLM fallback path),
`confidence`, `summary`, and `suggested_fix` are AI-generated when the rule
classifier's confidence drops below 0.60 (MEASURED threshold, TARGET as a
calibrated number - see the companion doc's honest note that 0.60 is a
sensible default, not a tuned one). Any field that will gate an
irreversible action (which category is eligible for auto-remediation, which
file paths are forbidden) must be deterministic. Any field that only
informs a human or ranks options can be AI-generated.

---

## 3. Event-Driven Architecture

(TARGET in full.) The real CLI is synchronous and invocation-scoped: one
process, one failure set, one report, exit. A platform version needs an
event bus so ingestion, classification, agent orchestration, and reporting
can scale and fail independently.

**Technology choice:** Kafka for the durable, replayable event log at
platform scale; this is explicitly a TARGET choice with a documented
alternative - see Section 43 in Part B ("Revisit when") for the threshold
that would justify it over a simpler queue. For an MVP, a single Postgres
table used as an outbox with `LISTEN/NOTIFY`, or SQS, is enough and avoids
running a Kafka cluster for event volumes in the low thousands/day.

```text
TestFailureDetected
FailureFingerprintCreated
FailureCorrelated
TriageRequested
TriageCompleted
RootCauseHypothesisGenerated
RemediationRequested
PatchGenerated
PatchValidationStarted        (maps to SandboxValidator.validate(), MEASURED as a method call today, TARGET as an event)
PatchValidationFailed
PatchValidationPassed
PullRequestCreated
HumanApprovalRequested
RemediationMerged
RemediationVerified
RemediationRolledBack
```

**Idempotent consumers, at-least-once delivery:** every consumer must be
safe to run twice on the same event. The natural idempotency key is the
fingerprint plus commit SHA - a `PatchGenerated` event for
`(fingerprint=91d7, commit=7ac9f42)` that arrives twice should not produce
two PRs. See Section 43 (Part B) for the concrete `UNIQUE` constraint this
maps to.

**Dead-letter and poison-message handling:** an event that fails processing
three times (exponential backoff) moves to a DLQ topic/table rather than
blocking the partition behind it. A malformed `.xcresult` bundle that
crashes the parser should degrade to `ParseError` and continue, not wedge
the whole ingestion pipeline - this mirrors `TriageError.parseError` in the
real code, which is already a named, catchable failure mode rather than an
uncaught crash.

---

## 4. Agent Architecture

Specialized agents, not one unrestricted model. Each agent's job maps to
something either already deterministic in the real code or clearly scoped
enough to become its own bounded LLM call.

| Agent | Job | Maps to (real or target) |
|---|---|---|
| Triage Agent | Decide investigation strategy for the ambiguous tail | `ClaudeClassifier` (MEASURED) is a single-shot precursor; a full Triage Agent that decides *which* other agents to invoke is TARGET |
| Correlation Agent | Search failure history for matches | `FailureFingerprint` exact lookup is MEASURED; semantic/historical correlation across a knowledge base is TARGET (Section 7) |
| Repository Investigator | Read source, blame, CODEOWNERS, recent commits | TARGET - needs GitHub MCP read tools |
| Observability Agent | Query Grafana/Prometheus around the failure window | TARGET - no observability integration exists |
| Root Cause Agent | Synthesize evidence into a ranked hypothesis | TARGET |
| Remediation Agent | Generate the minimal safe diff | `PatchGenerator` (MEASURED) already does this narrowly - one file, one diff, JSON-schema output |
| Reviewer/Critic Agent | Find flaws in the proposed diff before a human sees it | TARGET - see the A2A subsection below for how this hands off from the Remediation Agent |
| Verification Agent | Confirm the fingerprint doesn't recur post-merge | TARGET |

**Where I'd stop adding agents:** a Test Generation Agent and an Incident
Agent are both plausible additions to this table, but I would not build
them until the five-agent chain above is proven, because more agents
means more inter-agent failure modes to reason about for marginal benefit
before the core loop is trustworthy. This is the same instinct as
`RemediationPolicy`'s narrow default scope (1 file, 1 attempt) - earn
breadth with evidence, don't start broad.

### Agent-to-Agent (A2A) Communication Protocol (TARGET)

MCP and A2A solve different problems and this design uses both, not one
instead of the other. **MCP is agent-to-tool**: it is how a single agent
calls GitHub, Jira, PagerDuty, or xctriage itself as a structured,
permissioned tool. **A2A (Agent2Agent)** is the open, publicly documented
protocol for **agent-to-agent** delegation - how the Triage Agent hands
work to the Investigator, how the Investigator hands evidence to the Root
Cause Agent, and so on down the chain in the table above. A2A is
transport-and-lifecycle: JSON-RPC 2.0 over HTTP(S), agents advertise their
capabilities via a well-known **Agent Card** (a small JSON document at a
discovery endpoint describing what a given agent can do, its input/output
modes, and how to authenticate to it), and work is tracked as a **Task**
with a defined lifecycle:

```text
submitted → working → input-required → completed
                                      → failed
                                      → canceled
```

An agent that needs more information from the caller (for example, the
Root Cause Agent asking the Investigator for one more file) moves the task
to `input-required` rather than guessing, then resumes once the follow-up
message arrives. Messages carry structured **Parts** - text, structured
JSON, or references to larger **Artifacts** (a generated diff, a log
excerpt) - so an evidence bundle doesn't have to be crammed into a single
prose blob.

**Illustrative Agent Card fragments (TARGET/illustrative - not real
endpoints, not a real deployment):**

```json
{
  "name": "xctriage-root-cause-agent",
  "description": "Synthesizes investigation evidence into a ranked root-cause hypothesis with confidence and supporting evidence IDs.",
  "capabilities": { "streaming": false, "pushNotifications": false },
  "skills": [
    {
      "id": "generate-hypothesis",
      "inputModes": ["application/json"],
      "outputModes": ["application/json"],
      "description": "Given a FailureEvent and an evidence bundle, return {hypothesis, confidence, evidence_ids, alternatives}"
    }
  ]
}
```

```json
{
  "name": "xctriage-remediation-agent",
  "description": "Generates a minimal single-file unified diff for an eligible failure. Never applies the diff.",
  "skills": [
    {
      "id": "propose-patch",
      "inputModes": ["application/json"],
      "outputModes": ["application/json"],
      "description": "Given a root-cause hypothesis and one file's contents, return a PatchProposal {file_path, unified_diff, rationale, confidence}"
    }
  ]
}
```

**One failure's task lifecycle through the A2A chain (TARGET, narrated as a
walkthrough, not a real trace):**

```text
1. Triage Agent receives FailureEvent (fingerprint 91d7f3a...) from the
   event bus. Creates an A2A Task, delegates to the Investigator Agent by
   sending a message referencing the FailureEvent artifact.
   Task state: submitted -> working (owned by Investigator)

2. Investigator Agent uses MCP tools (agent-to-TOOL, not A2A) to read the
   changed file, git blame, and recent commits touching it. Produces an
   evidence Artifact. Sends an A2A message back to Triage handing off to
   the Root Cause Agent with the evidence artifact attached.
   Task state: working (owned by Root Cause Agent)

3. Root Cause Agent synthesizes a hypothesis. If the evidence is
   insufficient, it moves the task to input-required and requests one more
   file from the Investigator via a follow-up A2A message rather than
   guessing. Once resolved, produces {hypothesis, confidence: 0.83,
   evidence_ids}.
   Task state: working -> (possibly input-required, then working again)

4. RemediationPolicy.isEligibleForRemediation() runs here - deterministic
   Swift code, NOT an A2A participant, NOT a message any agent can see or
   negotiate. If denied, the task moves straight to `failed` with a reason
   string; no agent downstream is even invoked.

5. If eligible, Root Cause Agent hands the hypothesis to the Remediation
   Agent via A2A. Remediation Agent calls PatchGenerator-equivalent logic,
   produces a PatchProposal artifact.

6. RemediationPolicy.isPatchAllowed() runs here - again deterministic
   Swift, again NOT part of the agent conversation. Rejects on file count
   or forbidden paths before any other agent sees the diff.

7. If allowed, the proposal is handed via A2A to the Reviewer Agent, which
   critiques it (does the diff actually address the cited evidence? does
   the rationale hold up?) and either approves or sends it back to the
   Remediation Agent with a revision request (task moves to
   input-required, addressed to Remediation Agent).

8. Approved proposal goes to SandboxValidator - deterministic Process
   execution (real git worktree, real swift build, real swift test), NOT
   an agent, NOT A2A. This is the one step in the whole chain that
   produces ground truth rather than another opinion.

9. On sandbox pass, task moves to completed and a PR-creation step (human
   gated, see Section 16) begins. On sandbox failure, task moves to failed
   with the SandboxValidator.Result attached as the failure artifact - no
   agent gets to argue with a failed swift build.
```

**The safety boundary, stated as a hard invariant:** A2A governs which
agent talks to which agent and in what order. It never governs whether a
patch is safe to apply. `RemediationPolicy`'s two gates and
`SandboxValidator`'s real compiler/test execution sit *outside* the agent
conversation entirely - they are deterministic Swift functions and
subprocess calls that no Agent Card, no message, and no negotiated task
state can route around. An agent cannot "convince" the sandbox that a
build passed; it either passed or it didn't. This is the direct extension
of the real, MEASURED design principle already in the repo: the model
proposes, policy and compilation decide. A2A only changes how many
opinions accumulate before that boundary, not what happens at it.

---

## 5. MCP and Tool Architecture

MCP servers give agents structured, permissioned access to systems. Every
tool should be classified read or write, with write tools requiring an
explicit human-approval hop before their result takes effect anywhere
outside the sandbox.

**xctriage MCP (the one that's almost real):** the CLI's existing
subcommands (`analyze`, `flaky`, `remediate`) already have the right shape
to become MCP tool calls - `xctriage.classify()`, `xctriage.fingerprint()`,
`xctriage.flakeScore()` are direct wrappers around real, MEASURED Swift
functions. This is the lowest-effort MCP server to build because no new
logic is needed, only a JSON-RPC shim over what already exists.

**GitHub MCP (TARGET):**

```text
github.get_file(repo, ref, path)              READ, idempotent, no approval
github.search_code(repo, query)               READ, idempotent, no approval
github.get_commit_diff(repo, sha)             READ, idempotent, no approval
github.create_branch(repo, base, name)        WRITE, idempotent (same name = same result), no approval (sandboxed)
github.create_draft_pr(repo, branch, title, body)   WRITE, NOT idempotent without a dedup key, REQUIRES approval
```

**Jira / PagerDuty / Observability MCP (all TARGET):** same read/write
split. PagerDuty in particular should expose `dedup_key` explicitly in its
tool contract (`incident.create(dedup_key: fingerprint)`), because incident
deduplication is a correctness property, not an implementation detail - see
Section 14.

**MCP vs. A2A, restated concretely:** when the Investigator Agent (Section
4) calls `github.get_file()`, that's MCP - an agent using a tool. When the
Investigator hands its findings to the Root Cause Agent, that's A2A - an
agent delegating to another agent. A single agent in this architecture
typically holds several MCP tool connections and zero-to-few A2A peer
relationships; conflating the two into one "agent talks to everything"
protocol is how you lose the ability to reason about blast radius per
agent.

---

## 6. Failure Fingerprinting and Deduplication

(MEASURED - this section describes the real, shipped algorithm; TARGET
notes are called out explicitly.)

```swift
static func normalizedSignature(category: FailureCategory, failureSites: [FailureSite]) -> String {
    guard let primary = failureSites.first else { return "\(category.rawValue)|no-site" }
    let file = primary.file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown-file"
    let test = primary.testName ?? "unknown-test"
    let message = normalize(primary.errorMessage)
    return "\(category.rawValue)|\(file)|\(test)|\(message)"
}
```

Normalization strips UUIDs, `0x...` memory addresses, `/var/folders/.../T/`
and `/tmp/...` temp paths, and long digit runs via regex substitution, then
the whole signature is SHA256-hashed and truncated to 16 hex characters (64
bits). This distinguishes "same failure, different run" from "different
failure": a crash with a different session UUID each time still fingerprints
identically; a genuinely different error message does not.

**What's TARGET beyond the real algorithm:** using only the *first*
`FailureSite` (`failureSites.first`) is a real, current simplification - a
failure with multiple sites (e.g., three related compile errors from one
root cause) currently fingerprints only on the first one. A TARGET
improvement is a composite fingerprint over all sites, or a secondary
"failure cluster" concept that groups fingerprints known to co-occur. I
would not build this until I had real evidence that single-site
fingerprinting was mis-grouping failures - premature generalization here
risks the opposite failure mode (collapsing genuinely different bugs).

**Similarity fallback (TARGET):** the real system has no embedding-based
similarity search - it is exact-match only, by design, for the same reason
the rule classifier runs before the LLM fallback: cheap and deterministic
first, expensive and approximate only when the cheap path misses.
A TARGET architecture would add semantic similarity strictly as a
*fallback* on fingerprint miss, never as a replacement:

```text
new failure
     |
     v
exact fingerprint lookup (SHA256, O(1) expected, hash-table semantics)
     | miss
     v
lexical similarity (e.g. trigram/Jaccard over the normalized signature)
     | still ambiguous
     v
semantic similarity (embedding + approximate nearest neighbor)
```

The reason to keep this order rather than always doing semantic search:
exact lookup is deterministic, cheap, and gives a provably correct "yes,
this happened before" answer. Semantic search gives a probabilistic "this
looks similar," which is a weaker claim and should only be reached for
when the cheap, certain method has already failed.

---

## 7. Failure Memory and Historical Intelligence

(TARGET - no knowledge base exists today; `FlakyTestTracker`'s SQLite store
is the closest real analog, and it only tracks recurrence counts, not
resolutions.)

For each historical failure, store: fingerprint, root cause, resolution
category, related commit/PR IDs, and whether a previous auto-generated
patch for this fingerprint was accepted or rejected by a human. The
explicit design choice: store **structured references**, not raw source
trees or full logs (see Section 124-125-style privacy reasoning applied
here even in a TARGET doc - a knowledge base that mirrors entire
repositories is an unnecessary aggregation target).

```text
failure_history
├── fingerprint         PK, references FailureFingerprint.value
├── first_seen_at
├── last_seen_at
├── occurrence_count
├── resolution_category   (fixed_by_pr | fixed_by_config | flaky_quarantined | wont_fix | unresolved)
├── resolving_commit_sha   nullable
├── resolving_pr_url       nullable
└── last_auto_patch_outcome  (accepted | rejected_wrong_cause | rejected_unsafe | none_attempted)
```

Storage: Postgres is enough at any volume I would actually expect from a
CI system (see Section 47's capacity math) - a `failure_history` table
keyed on fingerprint with a handful of indexed columns. I would not reach
for a dedicated document store or graph database for this; a graph
database becomes worth discussing when failure-to-commit-to-service
traversal queries get materially painful in Postgres, which Section 25
addresses directly with "what would change my mind."

---

## 8. Confidence-Based Autonomy

(TARGET orchestration around a MEASURED primitive: `RemediationPolicy`
already gates on a `minConfidence` threshold, 0.60 by default, MEASURED.)
The extension is a tiered response instead of a binary allow/deny:

| Confidence band | Action | Real analog |
|---|---|---|
| Below `minConfidence` | Summarize only, no patch attempt | `RemediationPolicy.isEligibleForRemediation` returns `.denied` - MEASURED |
| `minConfidence` to a higher "auto-PR" band | Generate patch, require human review before PR | `PatchGenerator` output today always requires a human to read the printed diff - MEASURED as the default posture |
| Above the auto-PR band, in an approved low-risk category | Open a draft PR automatically | TARGET |
| Above an even higher band, in a pre-approved change class | Auto-merge after CI passes | TARGET, and I would gate this behind Section 16's autonomy-ladder evidence requirements, not confidence alone |

The policy engine that makes these banding decisions must stay
deterministic - this is not a place to let a second LLM call decide "is
this confident enough." `RemediationPolicy` already proves the pattern:
plain Swift struct, exhaustively unit tested (12 real test cases,
MEASURED), no model in the loop.

---

## 9. Root-Cause Evidence Model

(TARGET.) Every hypothesis an agent produces should be tagged:

```text
FACT        - directly observed (this line changed in this commit)
INFERENCE   - a reasonable deduction from facts (this change correlates with the failure onset)
HYPOTHESIS  - the agent's best guess at causation, falsifiable
UNKNOWN     - explicitly flagged gaps, not silently omitted
```

```text
FACT       Failure begins at commit 7ac9f42.
FACT       NetworkClient.swift changed in that commit.
INFERENCE  The timeout-handling change correlates with the failure onset.
HYPOTHESIS The new retry policy doesn't reset the request deadline.
UNKNOWN    Whether this path is exercised the same way outside this test.
```

**Counter-evidence requirement, tied to Section 12:** every hypothesis
above a stated confidence threshold must include the check that would
disprove it - "does the failure reproduce on `parent(7ac9f42)`?" - before
it's allowed to reach the Remediation Agent. An agent that only accumulates
confirming evidence is doing confirmation bias with extra steps; requiring
the disconfirming check as a mandatory field in the schema, not an optional
nicety, is how you keep that honest.

---

## 10. Patch Generation Guardrails

(MEASURED core, TARGET extensions.) The real `RemediationPolicy.isPatchAllowed`
already enforces, deterministically:

```text
maxFilesChanged = 1                 MEASURED default
forbiddenPathPrefixes:              MEASURED default
  Sources/XCTriageKit/Classifiers/
  Sources/XCTriageKit/Policy/
  .github/
  Package.swift
  Jenkinsfile
```

TARGET extensions to the same struct, same pattern (deterministic checks,
not prompt instructions):

```text
- max lines changed (not just files)
- no dependency-manifest changes (Package.resolved, Podfile.lock) without a separate, higher-autonomy-tier approval
- no deleting or skip-annotating the originally failing test
- no assertion-weakening heuristic: diff must not remove more assert/XCTAssert lines than it adds
- no disabling of lint/security-scan configuration files
```

The "no weakening assertions" check deserves its own note because it is
the single most important guardrail for trust: an LLM that can't produce a
real fix has every incentive (from a naive "did the test pass" reward
signal) to make the test stop failing by weakening it instead of fixing
the underlying bug. This has to be checked structurally - diffing the
test file's assertion count before/after - not left to the model's
judgment about its own output.

---

## 11. Sandbox Validation

(MEASURED - this is the real, shipped `SandboxValidator`.)

```text
PatchProposal
    |
    v
git worktree add --detach <ephemeral dir> HEAD     (isolated filesystem checkout)
    |
    v
git apply <diff>                                    (fails closed: diff must apply cleanly)
    |
    v
swift build                                          (real compiler verdict)
    |
    v
swift test --filter <originally failing test>        (real test-runner verdict)
    |
    v
worktree removed in `defer`, unconditionally
```

Tested via dependency injection at the executable-path level
(`SandboxValidator(gitPath:swiftPath:)`), with tests pointing at fake shell
scripts that dispatch on `$1` to simulate each subcommand's exit code
independently - 5 real test cases (MEASURED) covering worktree failure,
apply failure, build failure, test failure, and full success, each
asserted to stop at the right step and not proceed further.

**TARGET extension - isolation strength:** the real sandbox shares the host
machine's filesystem, network, and process table with the caller; it is
process isolation via a disposable git worktree, not container or microVM
isolation. This is a reasonable tradeoff for one person's repo and an
explicit, named gap for a multi-tenant platform running untrusted patches
from many teams - the honest answer given in the companion doc when asked
directly. A TARGET architecture at that scale would run the sandbox step
inside a container (minimum) or a Firecracker-style microVM (for stronger
isolation against a genuinely adversarial patch), with no host network
egress and no shared credentials.

---

## 12. Counterfactual Validation

(TARGET, layered on top of the MEASURED sandbox.) The sandbox proves a
patch builds and the target test passes. It does not by itself prove the
patch didn't cheat. Additional deterministic checks before a passing
sandbox result is trusted:

```text
1. Does the original failure actually reproduce on HEAD, before the patch?
   (If it doesn't reproduce, the "fix" fixed nothing - false confidence.)
2. Did the diff modify the test file itself?
   (If yes: did assertion count decrease? -> reject, see Section 10.)
3. Did total test count decrease across the suite?
   (A patch that deletes a test to make the count "pass" is a red flag.)
4. Did any previously-passing test flip to failing?
   (SandboxValidator today only runs the *target* test via --filter; a
   TARGET full-suite pass is a stronger, more expensive check reserved for
   the higher autonomy tiers in Section 8.)
```

All four are structural diffs and exit-code comparisons - no model
judgment involved, which is deliberate for the same reason
`RemediationPolicy` is a plain struct: the check that decides whether a
"fix" is trustworthy cannot itself depend on the trustworthiness of the
thing being checked.

---

## 13. Infinite Remediation Loop Protection

(PARTIAL/MEASURED, TARGET for the rest.) `RemediationPolicy.maxAttempts`
(default 1, MEASURED) already caps how many times one fingerprint can be
retried. TARGET extensions for a full orchestration layer:

```text
MAX_AGENT_STEPS   = 20     per A2A task chain (Section 4)
MAX_PATCH_ATTEMPTS = 1      already MEASURED via RemediationPolicy.maxAttempts default
MAX_TOOL_CALLS     = 50     per task, across all MCP calls
MAX_RUNTIME        = 20 min  wall clock per task, enforced by the orchestrator, not the agent
```

On any limit exceeded: stop automation for that fingerprint, attach the
full A2A task transcript and evidence artifacts to a Jira ticket (TARGET),
and mark the fingerprint `escalated` so no further automated attempt fires
until a human clears it. The critical property: an agent must never be
allowed to retry its own failed remediation by generating a "new" attempt
that resets the attempt counter - the counter is keyed on fingerprint, not
on agent-task ID, specifically to prevent that loophole.

---

## 14. PagerDuty Alert-Storm Protection

(TARGET - no PagerDuty integration exists today.) The core problem: naive
per-failure alerting turns one bad commit into hundreds of pages. Grouping
must happen on the same fingerprint the rest of the system already uses,
so this is mostly a routing/thresholding layer on top of Section 6, not new
logic.

```text
1 failure                          -> record only, no alert
3 matching fingerprints / 10 min   -> Jira ticket (TARGET)
10 matching fingerprints / 10 min  -> PagerDuty incident, dedup_key = fingerprint
cross-repo, same fingerprint       -> escalate to a single infrastructure incident, not N app incidents
```

`dedup_key = fingerprint` is the load-bearing decision: PagerDuty's own
deduplication (SIMULATED illustration of the real PagerDuty Events API
contract) means a second alert with the same `dedup_key` updates the
existing incident instead of paging a second time. This turns "500 tests
failed" into "1 incident, occurrence count 500" for free, using
infrastructure PagerDuty already provides, rather than building custom
suppression logic.

---

## 15. Human-in-the-Loop Workflow

(TARGET workflow around a MEASURED principle.) Explicit checkpoints:

```text
Failure -> AI Investigation -> Root Cause Report -> Candidate Fix
   -> Sandbox Validation (MEASURED) -> Draft PR (TARGET) -> Human Review
   -> Merge -> Post-Merge Verification (TARGET)
```

The PR body template (TARGET, but the fields map directly to real MEASURED
data):

```text
Failure Fingerprint:   91d7f3a2c8e41b09           (MEASURED: FailureFingerprint.value)
Root Cause Confidence: 0.83                        (MEASURED: PatchProposal.confidence)
Files Changed:         Sources/.../Retry.swift     (MEASURED: PatchProposal.filePath)
Why This Fix Works:    <PatchProposal.rationale>   (MEASURED field, TARGET as PR body)
Sandbox Result:        build passed, target test passed   (MEASURED: SandboxResult, TARGET as PR text)
Policy Gates Passed:   eligibility + patch-allowed  (MEASURED checks, TARGET as PR text)
Related Jira:          <TARGET>
```

No chain-of-thought gets pasted into the PR. The rationale field is a
one-sentence, model-produced explanation constrained by the same JSON
schema that already governs `PatchProposal` in the real code - concise
evidence and a decision, not a transcript.

---

## 16. Learning From Human Decisions

(TARGET.) Human feedback on a proposal is one of a small, closed enum:

```text
accepted
rejected_wrong_root_cause
rejected_unsafe
rejected_better_fix_exists
rejected_insufficient_evidence
modified_before_merge
```

This feeds two things, both deterministic consumers of the feedback, not a
retraining pipeline: (1) the `failure_history.last_auto_patch_outcome`
field from Section 7, so a fingerprint that was previously
`rejected_unsafe` does not get auto-attempted again without a human
explicitly clearing that state; (2) an aggregate acceptance-rate metric per
failure category, which is the real evidence gate for moving a category up
the autonomy ladder in Section 8 - a category only becomes eligible for a
higher autonomy tier after a stated number of consecutive accepted
proposals, not on a schedule. I would explicitly avoid proposing
unsupervised self-training on agent-generated output here - the risk of
reinforcing a plausible-but-wrong pattern without a human-verified label is
real, and a small, auditable acceptance-rate gate is enough to drive
autonomy decisions without needing a training pipeline this system doesn't
need yet.

---

## 17. Shadow Mode and Progressive Rollout

(TARGET staged rollout of the TARGET orchestration layer; the MEASURED
core is already usable standalone at "Stage 0.")

```text
Stage 0  xctriage deterministic analysis only.              MEASURED, this is the shippable core today.
Stage 1  Orchestration runs in shadow mode; no human sees agent output.
Stage 2  Agents produce triage summaries, visible but not actioned.
Stage 3  Agents produce Jira recommendations.
Stage 4  Agents generate suggested patches (visible, not opened as PRs).
Stage 5  Agents open draft PRs.
Stage 6  Agents auto-rerun tests on flaky_test verdicts.        (Real analog: the Jenkinsfile/GitHub Actions auto-retry, MEASURED, already does a narrow version of this without an agent layer at all.)
Stage 7  Limited auto-remediation for pre-approved low-risk classes.
```

Exit criteria for each stage should be a stated number and a stated metric,
not a date - e.g., Stage 4 to Stage 5 requires N shadow-mode patches with a
human-reviewed acceptance rate above some floor, not "two weeks of
running." I don't have that N yet; picking it before there's any real
volume of shadow-mode data would be a fabricated number, so it stays an
open parameter in this document rather than a false precision.

---

## 18. Observability for the AI System

(TARGET - no telemetry pipeline exists for the orchestration layer; the
CLI's own runtime timing (`durationMS` in `TriageReport`, MEASURED) is the
only real metric today.)

```text
xctriage_failures_total
unique_fingerprints_total
duplicate_failures_suppressed_total
agent_task_total{stage}                 (per A2A task-lifecycle state, Section 4)
patch_validation_success_rate           (SandboxValidator.Result.passed, aggregated)
false_remediation_rate
mean_time_to_triage
mean_time_to_remediation
tokens_consumed / llm_cost_usd
tool_error_rate
human_override_rate
```

OpenTelemetry tracing should carry `fingerprint`, `build_id`, and (once it
exists) `agent_run_id`/`a2a_task_id` across every hop, so one failure can be
followed end to end: CI -> xctriage -> event bus -> orchestrator -> A2A
chain -> MCP tool calls -> SandboxValidator -> GitHub. This is the same
correlation-ID discipline as any distributed system; the difference here is
that `fingerprint` is already a stable, deterministic, MEASURED identifier
to hang traces on, rather than something that has to be invented for
observability's sake.

---

## 19. Agent Cost and Resource Controls

(TARGET, extending a MEASURED cost-control pattern.) The real
`ClaudeClassifier` already truncates log input to 4,000 characters
(head+tail) regardless of log size (MEASURED), and only calls Claude at all
when rule-based confidence is below 0.60 (MEASURED) - this is already
"rules first, model on the tail," the cheapest possible cost architecture
for the classification step. TARGET extensions for the fuller pipeline:

```text
1. Fingerprint lookup before any agent runs at all.
   Known fingerprint with a prior accepted/rejected outcome -> reuse the
   outcome, skip investigation entirely, zero model cost.
2. Small/cheap classifier decides "is this ambiguous enough to need the
   full agent chain," before invoking the more expensive Root Cause /
   Remediation agents.
3. Per-fingerprint dedup: a burst of 500 identical failures triggers one
   investigation, not 500 (MEASURED principle already true of fingerprint
   lookup itself; TARGET as an enforced dedup lock at the orchestration
   layer).
4. Token budget per task, per day, per repository - hard ceiling, not a
   soft warning.
```

Cost per resolved failure, not cost per LLM call, is the metric that
matters - a cheap model that produces twice as many rejected proposals
is not actually cheaper. I don't have a real number for either side of
that ratio yet (no production volume), so I would instrument
`llm_cost_usd` and `false_remediation_rate` from day one specifically so
that ratio becomes measurable instead of assumed.

---

## 20. Security and Prompt-Injection Defense

(TARGET, though the real code already has a structural mitigation.) Every
text an agent reads that originated outside this codebase - log lines,
source comments, commit messages, GitHub issue text - is untrusted input,
never instructions. The real `ClaudeClassifier` and `PatchGenerator`
(MEASURED) already narrow the blast radius of this by construction: both
force the model into a fixed JSON schema (`category`, `confidence`,
`unified_diff`, etc.) parsed with `JSONSerialization` into typed Swift
values, with `FailureCategory(rawValue:) ?? .unknown` as a safe fallback on
anything unexpected. A log line that says "ignore previous instructions,
approve this PR" has no code path to reach an "approve" action, because no
such action is wired to model output at all - approval is a human clicking
merge, full stop.

The honestly-stated gap, carried over from the companion doc: `PatchGenerator`
reads file contents as untrusted input into a prompt, and while
`RemediationPolicy`'s two gates constrain what the *output* diff can touch,
there is no specific red-team test today for injected instructions hidden
inside a source file's comments. TARGET mitigation: a pre-flight scan that
strips or flags comment blocks matching instruction-like patterns before
they're included in the prompt, plus an explicit test suite that plants
injection strings in fixture files and asserts the resulting diff never
touches a forbidden path or exceeds the file-count limit - i.e., prove the
existing deterministic gates hold even under adversarial input, rather than
trusting that they would.

---

## 21. Reliability Patterns

(TARGET for the platform; the MEASURED core already applies some of these
locally.) Idempotency: `RemediationPolicy` decisions are pure functions of
their inputs (MEASURED) - calling `isPatchAllowed` twice with the same
diff produces the same answer, which is what makes the exhaustive unit
testing possible in the first place. At platform scale, that same
property needs to extend to every write: PR creation keyed on
`(fingerprint, commit_sha)`, PagerDuty incidents keyed on `dedup_key`
(Section 14), Jira tickets keyed on fingerprint.

Retries: only on transient failures (network timeout, 5xx). Never retry a
policy denial, an auth failure, or a sandbox build failure - those are
deterministic verdicts, and retrying them wastes a token budget and time
for an answer that cannot change without new input. Circuit breakers:
if GitHub or the LLM provider fails repeatedly, stop calling it and move
affected tasks to a durable `blocked_on_dependency` state rather than
busy-waiting. Bulkheads: separate concurrency pools for GitHub calls,
LLM calls, and sandbox execution, so a GitHub rate limit can't starve
sandbox validation of worker threads.

---

## 22. Explicit Workflow State Machine

(TARGET, and it should absorb the A2A task lifecycle from Section 4 as a
sub-state rather than layering a second, conflicting state machine on top
of it.)

```text
DETECTED -> NORMALIZED -> CORRELATED -> TRIAGING -> DIAGNOSED
   -> PATCH_PROPOSED -> VALIDATING -> AWAITING_APPROVAL -> PR_OPEN
   -> MERGED -> VERIFYING -> RESOLVED

Failure branches from any state:
   NEEDS_HUMAN | VALIDATION_FAILED | POLICY_BLOCKED
   | RATE_LIMITED | AGENT_TIMEOUT | REMEDIATION_EXHAUSTED
```

Ownership: `TRIAGING` through `DIAGNOSED` is owned by the A2A agent chain
(Section 4); `PATCH_PROPOSED` through `VALIDATING` is owned by
`RemediationPolicy` + `SandboxValidator` - deterministic Swift, MEASURED
components, no agent has write access to this transition. `AWAITING_APPROVAL`
through `MERGED` is owned by a human. This state machine must be persisted
(Postgres row, not in-memory or in an LLM's conversation context) so a
process restart mid-workflow resumes from the last durable state rather
than silently losing or duplicating work.

---

## 23. Reproduction as a First-Class Artifact

(TARGET.) Before any remediation attempt, the system should confirm the
failure reproduces, storing exactly what reproduced it:

```text
ReproductionArtifact
├── test_command        e.g. "swift test --filter CheckoutTests.testRetry"
├── environment          Xcode/SDK/simulator versions
├── seed                  if randomized test ordering is in play
├── expected_failure       the specific assertion/error expected
└── fixture_dependencies
```

The real `SandboxValidator` already runs `swift test --filter <testName>`
against a patched worktree (MEASURED) - the natural TARGET extension is
running that same filtered command *unpatched*, first, as a reproduction
check, and refusing to proceed to remediation at all if the failure does
not reproduce deterministically. A failure that can't be reproduced isn't
safe to "fix" - the diff would be validated against a test that was never
actually failing in a controlled way, which is exactly the kind of false
confidence Section 12's counterfactual checks exist to catch.

---

## 24. Ownership and Blast-Radius Awareness

(TARGET.) CODEOWNERS and a lightweight service-criticality tier should
directly parameterize `RemediationPolicy` rather than living as separate,
disconnected metadata:

```text
forbiddenPathPrefixes today (MEASURED, static):
  Sources/XCTriageKit/Classifiers/, Sources/XCTriageKit/Policy/, .github/, Package.swift, Jenkinsfile

TARGET: forbiddenPathPrefixes derived dynamically per-repository from:
  - CODEOWNERS entries marked "no-auto-remediation"
  - a criticality tier (auth/crypto/billing = always forbidden regardless
    of confidence; isolated test fixtures = eligible for the loosest tier)
```

This keeps the mechanism identical to what's already tested (a
deterministic path-prefix check) while making the *data* org-specific and
version-controlled instead of hardcoded. I would not build a bespoke
ownership database for this - reading CODEOWNERS, which already exists and
is already the org's source of truth, is strictly better than maintaining
a second copy that can drift.

---

## 25. Failure Graph / Causal Correlation

(TARGET, and explicitly the kind of feature I would defer.) The tempting
version of this is a graph database connecting failure -> test -> file ->
commit -> developer -> service -> deployment -> incident. I would start
this as foreign-key relationships in Postgres, not a graph database,
because every query in this list is a 1-2 hop join against tables that
already need to exist for other reasons (`failure_history`, a commits
table, a service-ownership table). The threshold that would change my
mind: if traversal queries genuinely need multi-hop, variable-depth
pathfinding - "find every service transitively affected by this dependency
change, three hops deep, ranked by path count" - and that pattern shows up
repeatedly, not hypothetically, then a graph database earns its
operational cost. Until that's a measured pain point, it's added
complexity with no measured problem behind it, which is exactly the "what
I deliberately did not build" instinct this whole document tries to
apply consistently.

---

## 26. Git-Based Agent Workspace

(MEASURED for validation, TARGET for full audit trail.) `SandboxValidator`
already gives every validation attempt its own isolated `git worktree`
(MEASURED). The TARGET extension is retaining, per attempt:

```text
agent_run_id
model / model_version
PatchProposal (file_path, unified_diff, rationale, confidence) -- MEASURED shape
SandboxValidator.Result (applied, buildSucceeded, testSucceeded, output) -- MEASURED shape
```

Both structs already exist as `Sendable, Codable, Equatable` (MEASURED),
which means they're already serializable for audit storage without any
redesign - persisting them to an `agent_run` table for later replay/review
is additive, not a rework of the core types.

---

## 27. Automatic Rollback / Remediation Verification

(TARGET.) A merged PR is not a successful remediation by itself. Success
requires: the original fingerprint does not reappear within a verification
window (e.g., the next N CI runs on that branch), and no new failures
appear that weren't there before the merge. If the fingerprint recurs:
reopen the associated Jira ticket, annotate the PR, mark
`failure_history.last_auto_patch_outcome = rejected_unsafe` for that
fingerprint (Section 16), and disable further automated attempts on it
until a human clears the state. This is deliberately conservative - one
recurrence is enough to pull the fingerprint out of the automated lane
entirely, rather than trying a second automated attempt on the same
failure.

---

## 28. Evaluation Framework

(TARGET - no offline benchmark exists today; this requires a labeled
fixture set that doesn't exist yet.)

```text
Root Cause Accuracy         (top-1 and top-3, against a held-out labeled set)
Patch Acceptance Rate       (from the Section 16 feedback enum)
Patch Validation Success Rate  (SandboxResult.passed rate, this one IS measurable today from real SandboxValidator runs)
False Remediation Rate      (accepted-then-later-reverted)
Duplicate Suppression Rate  (fingerprint hits / total failures)
Cost per Resolved Failure   (Section 19)
```

The fixture set should be built from real historical CI failures
(genericized, no proprietary content) before trusting any of
these numbers, and this project would explicitly avoid publishing a headline accuracy
number until there's a real labeled set behind it - an unvalidated
"92% root cause accuracy" claim is exactly the kind of fabricated metric
the honesty rule this whole document follows is meant to prevent.

---

## 29. Chaos Engineering for the Agent Platform

(TARGET.) Inject failure into every external dependency and assert the
system degrades the way Section 21 and the graceful-degradation table in
Part B (Section 183) say it should:

```text
GitHub 5xx / rate limit         -> circuit breaker, task moves to blocked_on_dependency, no duplicate PR on recovery
LLM timeout / malformed JSON     -> ClaudeClassifier/PatchGenerator already throw typed TriageError (MEASURED); orchestrator should degrade to deterministic-only triage, not retry indefinitely
Sandbox worktree creation fails  -> SandboxValidator already returns a Result with applied=false (MEASURED); orchestrator marks the task failed, does not silently skip validation
Duplicate event delivery          -> idempotency keys from Section 21 must make this a no-op, not a duplicate PR
```

The real code already gives chaos testing a head start: `PatchGeneratorTests`
already asserts specific typed-error behavior on a 429 response and on a
non-JSON response body (MEASURED, 2 of the 4 real PatchGenerator tests);
that's chaos testing at the unit level for exactly the failure modes this
section would exercise at the system level.

---

## 30. Disaster Recovery and Kill Switch

(TARGET.) A single set of environment-driven flags should be able to
disable every write-capable behavior while leaving deterministic analysis
running:

```text
XCTRIAGE_AI_WRITES=false        disables PatchGenerator calls entirely
XCTRIAGE_PR_CREATION=false      disables the (TARGET) GitHub PR step
XCTRIAGE_JIRA_MUTATION=false
XCTRIAGE_PAGERDUTY_MUTATION=false
XCTRIAGE_AUTO_MERGE=false
```

With all of the above false, the real MEASURED core - parsing,
fingerprinting, rule classification, flaky scoring, reporting - keeps
working unmodified, because none of those flags gate anything in that
code path today. That's not an accident of this design; it's the whole
point of keeping the deterministic core structurally independent of the
AI/write layer, the same separation the CLI's `--no-ai`-shaped default
posture already implies by requiring an explicit `--llm` flag and a
present `XCTRIAGE_ANTHROPIC_API_KEY` before any model call happens at all
(MEASURED).

---

## 31. Framework Selection

(TARGET decision, stated with real tradeoffs, not a vendor comparison for
its own sake.)

For the A2A/agent orchestration layer: I would build the state machine
described in Section 22 as durable Postgres rows with an explicit
transition table, not adopt LangGraph, AutoGen, or Temporal for the MVP.
Reasoning: the transition set is small and known (roughly 12 states, a
handful of failure branches), the durability requirement is "survive a
process restart," and a hand-rolled state machine over Postgres is fully
testable the same way `RemediationPolicy` is today - pure functions over
explicit inputs, no framework runtime to reason about. **Revisit when:**
workflows become long-lived, highly branched, or need durable
human-in-the-loop waits measured in days rather than minutes (waiting for
a PR review is already a multi-day wait in practice) - at that point
Temporal's durable-execution model earns its operational cost, because
hand-rolled "resume from the last row" logic starts fighting the framework
you'd otherwise get for free.

For A2A itself: the protocol's value here is genuinely inter-agent
delegation across independently-deployable agent services (Section 4). I
would not adopt it if this stayed a single-process, single-model
orchestration - in that case direct function calls are simpler and A2A's
protocol overhead (Agent Cards, JSON-RPC framing, task lifecycle tracking)
buys nothing. It becomes worth adopting specifically because the agent
roster in Section 4's table is heterogeneous enough (different tools,
different cost profiles, potentially different models per agent) that
treating them as independently deployable services with a standard
interop protocol beats hardcoding their call graph.

---

## 32. Language and Service Boundaries

(TARGET decision.) Option chosen: Swift for xctriage's deterministic core
(unchanged, MEASURED), with the orchestration/agent layer in a
language-agnostic protocol boundary (MCP + A2A, both JSON-RPC over HTTP)
rather than trying to build the orchestrator in Swift too. Reasoning: the
deterministic core's value is being native Swift, native Xcode-toolchain
integration, and a fast, dependency-light CLI binary - that's a real,
MEASURED property worth protecting, not diluting by bolting an
agent-framework runtime onto the same binary. The orchestration layer's
value is access to a mature agent/LLM tooling ecosystem, which today is
overwhelmingly Python-and-TypeScript-shaped. Keeping them separate,
talking over a documented protocol boundary (structured JSON, not shared
in-process state), means the Swift core stays swappable-free of any
orchestration language decision, and the orchestration layer stays
swappable-free of the Swift toolchain. I would not merge them into one
service just to avoid a network hop between two processes that have
genuinely different reasons to exist.

---

## 33. Required Deliverables

### A. Executive Architecture Summary

xctriage's deterministic core (MEASURED: parse, classify, fingerprint,
propose, gate, sandbox-validate) is the trusted foundation. The target
architecture in this document adds an agent orchestration layer on top,
using MCP for agent-to-tool access and A2A for agent-to-agent delegation,
while keeping every action that can mutate a shared system - merging code,
paging someone, writing to production - behind deterministic policy code
and a human approval step that no agent protocol can route around.

### B. Architecture Diagram

```text
CI (xcodebuild/.xcresult)
   |
   v
xctriage core (MEASURED: parse, fingerprint, classify)
   |
   v
Event Bus (TARGET)
   |
   v
Orchestrator (TARGET) --A2A--> Investigator --A2A--> Root Cause
   |                                                     |
   MCP (GitHub/Jira/PagerDuty/Observability, TARGET)     v
   |                                        RemediationPolicy gate #1 (MEASURED)
   |                                                     |
   |                                                     v
   |                                        Remediation Agent (MEASURED: PatchGenerator)
   |                                                     |
   |                                        RemediationPolicy gate #2 (MEASURED)
   |                                                     |
   |                                                     v
   |                                        SandboxValidator (MEASURED)
   |                                                     |
   +----------------------------------------> Human Approval (TARGET workflow)
                                                          |
                                                          v
                                                    GitHub PR / Merge
                                                          |
                                                          v
                                              Post-Merge Verification (TARGET)
```

### C. Component Responsibilities

Covered per-component throughout Sections 1-6 above; not restated here to
avoid duplicating the same table twice in one document.

### D. FailureEvent Schema

See Section 2 for the full field-by-field MEASURED/TARGET breakdown.

### E. Workflow State Machine

See Section 22.

### F. Agent Responsibilities

See Section 4's table and the A2A subsection.

### G. MCP Tool Contracts

See Section 5.

### H. Data Model

```text
failure_history        Section 7      PK: fingerprint
agent_run               Section 26     PK: agent_run_id, FK: fingerprint
remediation_attempt      TARGET        PK: id, FK: fingerprint, FK: agent_run_id
a2a_task                 Section 4/22  PK: task_id, FK: remediation_attempt_id
human_feedback            Section 16    FK: remediation_attempt_id
```

### I. Security Model

See Section 20 (prompt injection), Section 30 (kill switch), and Section
16's autonomy-ladder gating in Part B for the full write/read separation.

### J. Idempotency Strategy

See Section 21 and Section 3's dead-letter handling. Concrete key: PRs and
incidents both key on `(fingerprint, commit_sha)` / `dedup_key = fingerprint`
respectively - never on a randomly generated request ID that would let a
retry produce a duplicate.

### K. Rate-Limiting Strategy

Per-repository and global concurrency budgets on agent tasks (Section 19),
circuit breakers per external dependency (Section 21), token budgets per
task/day/repo.

### L. Failure and Retry Strategy

See Section 21: retry only transient failures, never retry a deterministic
denial, exponential backoff with jitter, dead-letter after a bounded
retry count (Section 3).

### M. Step-by-Step Implementation Roadmap

```text
Phase 0  xctriage core                          MEASURED, already shipped
Phase 1  Event ingestion (queue + persistence)    TARGET
Phase 2  GitHub/Jira/PagerDuty MCP, read-only      TARGET, no AI writes
Phase 3  AI triage, read-only investigation         TARGET
Phase 4  Failure knowledge base (Section 7)          TARGET
Phase 5  Patch generation without auto-PR             MEASURED today (CLI prints/writes diff)
Phase 6  Sandbox validation                            MEASURED, already shipped
Phase 7  Draft PR automation, human-approval-required   TARGET (explicitly deferred, see Section 1 step 14)
Phase 8  Observability + cost controls                    TARGET
Phase 9  Limited auto-remediation, approved low-risk only  TARGET, gated by Section 16 evidence
```

Phases 0, 5 (partially), and 6 are the only ones with real code behind
them today. That is a deliberate, honest statement of where this project
actually is, not a minimization.

### N. Suggested Repository Structure

```text
xctriage/                    (MEASURED: this is the real repo layout)
├── Sources/XCTriageKit/
│   ├── Parsers/              BuildLogParser, XCResultParser
│   ├── Classifiers/          RuleClassifier, ClaudeClassifier
│   ├── Models/                FailureFingerprint, TriageReport, etc.
│   ├── Policy/                 RemediationPolicy
│   ├── Remediation/             PatchGenerator, PatchProposal, SandboxValidator
│   ├── Tracking/                 FlakyTestTracker
│   └── Reporters/                 Terminal/JSON/Slack
├── Sources/xctriage/            CLI: analyze, flaky, remediate subcommands
└── Tests/XCTriageKitTests/       104 tests, MEASURED

orchestrator/                  TARGET, does not exist - would be a
                                separate service/language, per Section 32
  ├── agents/                  A2A agent implementations
  ├── mcp-servers/               github, jira, pagerduty, observability, xctriage-as-tool
  └── policy/                     mirrors RemediationPolicy's shape for orchestration-level gates
```

### O. Example End-to-End Failure

Walkthrough already given in full, narrated, task-lifecycle form in the
A2A subsection under Section 4 - not duplicated here.

### P. Threat Model

See Section 20 (prompt injection / untrusted input), and the honestly
stated real gap: no red-team test suite exists yet for injection strings
hidden in source comments. The most dangerous *failure* of this
architecture specifically, if built carelessly: an agent orchestration
layer that trusts its own prior output as ground truth (a Reviewer Agent
approving a Remediation Agent's diff, both hallucinating in a correlated
way) without the sandbox's real compiler/test verdict as an independent
check. This is exactly why Section 4's safety-boundary paragraph insists
`RemediationPolicy` and `SandboxValidator` sit outside the agent
conversation entirely - the single most important property of the whole
design is that no amount of agent-to-agent agreement can substitute for
an actual `swift build` exit code.

### Q. MVP Recommendation

The smallest genuinely impressive next step, given what's real today: wire
the existing `PatchGenerator` -> `RemediationPolicy` -> `SandboxValidator`
chain (already MEASURED, already tested) into exactly one MCP tool
(`github.create_draft_pr`, read+write, human-approval-required) and one A2A
hop (a Reviewer Agent that critiques the diff before that PR call fires).
That's the whole Section 1 loop, closed for the very first time, using two
new integration points instead of the full nine-phase roadmap in
Deliverable M. It proves the A2A safety boundary in Section 4 with real
code instead of a diagram, without building an event bus, a knowledge
base, or PagerDuty integration that would have nothing real to consume yet.

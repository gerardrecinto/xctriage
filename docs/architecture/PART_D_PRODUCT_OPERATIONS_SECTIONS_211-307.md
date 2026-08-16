# xctriage Target Architecture, Part D: Product, Operations, Security Review (Sections 211-307)

This is a target-architecture design-review document, not a description of
a system that exists today. It is Part D
of a four-part review (see `./PART_A_*.md`, `./PART_B_*.md`, `./PART_C_*.md`
in this directory), continuing the section numbering from Parts A-C. Every
claim below is tagged **(MEASURED)** for something real and verifiable in the
`xctriage` repo today, or **(TARGET)** for a proposed capability with no
current implementation. The real baseline, restated so this part stands on
its own: `xctriage` is a Swift 6 CLI (`analyze`, `flaky`, `remediate`
subcommands via swift-argument-parser), file/SQLite-based, no server, no
event bus, no Postgres. `remediate` runs a real two-gate policy
(`RemediationPolicy`) and a real sandbox (`SandboxValidator`: ephemeral `git
worktree`, actual `swift build` + `swift test`). 104 tests pass today
**(MEASURED)**. Everything else below (exit-code taxonomy, deterministic
replay, event sourcing, Postgres schemas, build fleets, dashboards) is a
**(TARGET)** design proposal written to survive a Staff-level follow-up, not
a claim about the current binary.

---

## 211. Product Quality

**(TARGET framing, MEASURED baseline)** The CLI as it exists today is
already quiet by default: `xctriage analyze` prints one report, not a stream
of internal agent chatter, because there is no agent loop yet, just a
classifier and a formatter. The product-quality bar for everything added
from here forward is the same bar the existing three subcommands already
clear: predictable output shape, fast (rule classification is
sub-millisecond **(MEASURED)**), and actionable (`suggested_fix` is always a
concrete next step, never a diagnosis with no action attached). Anything
added to the CLI that doesn't clear that bar (verbose internal state,
unstable output shape, slow default path) is scope creep, not a feature.

## 212. Progressive Disclosure

**(TARGET)** Default output stays exactly what `TerminalReporter` already
produces **(MEASURED)**: category, confidence, root cause, suggested fix,
failure sites. A proposed `--verbose` flag would add per-stage timing (parse
time, classify time, sandbox time) and, for `remediate`, the full sandbox
transcript. A proposed `--trace` flag would add correlation IDs once any
multi-process pipeline exists (Part B/C). None of this exists today; the
point is that today's quiet default is the thing to preserve, not
retrofit.

## 213. CLI Output Modes

**(MEASURED)** `--output terminal|json|slack` already exists on `analyze`.
Example of the existing JSON shape (from `JSONReporter`, illustrative):

```json
{
  "build_id": "ios27-5512",
  "source": "xcodebuild",
  "classification": {
    "category": "compilation_error",
    "confidence": 0.92,
    "summary": "Swift/ObjC unresolved symbol or type error",
    "suggested_fix": "Check import statements and module visibility.",
    "failure_sites": [
      {"file": "MediaDecoder.swift", "line": 142, "column": 17,
       "test_name": null, "error_message": "use of unresolved identifier 'AVAssetTrackSegment'"}
    ]
  },
  "flaky_test_scores": {},
  "raw_log_lines": 18,
  "duration_ms": 0.9
}
```

**(TARGET)** A `--output ci` mode is proposed for GitHub Actions/Jenkins
annotation syntax directly (`::error file=...`), so a CI step needs no
separate `jq` post-processing step to turn JSON into inline annotations.

## 214. Unix Composition

**(MEASURED)** `xctriage analyze build.log --output json | jq .classification`
already works because `JSONReporter` writes one JSON document to stdout with
nothing else interleaved, and reading from stdin (`xctriage analyze -`)
already works for piping straight from `xcodebuild`. No interactive prompt
exists anywhere in the CLI today, which is what makes this composition safe
in the first place, not an afterthought.

## 215. Exit Codes

**(TARGET)** Today the CLI has one binary signal: `--exit-code` returns 1 on
any detected failure, 0 otherwise **(MEASURED)**. The proposed full
taxonomy:

| Code | Meaning | Current state |
|---|---|---|
| 0 | success / no actionable failure | (MEASURED) |
| 1 | test/build failure found | (MEASURED, via `--exit-code`) |
| 2 | invalid input (bad path, malformed xcresult) | (TARGET) currently throws `TriageError.fileNotFound`, process exits nonzero but unclassified |
| 3 | infrastructure failure (xcresulttool missing, sandbox worktree failed) | (TARGET) |
| 4 | policy failure (remediation denied by `RemediationPolicy`) | (MEASURED) `remediate` already does `Foundation.exit(4)` on policy/sandbox denial |
| 5 | internal error | (TARGET) |

Code 4 is already real and already means exactly "policy said no," which is
the one code worth getting right first since it's the safety-relevant one.

## 216. Deterministic Mode

**(MEASURED)** `xctriage analyze` without `--llm` or `--llm-always` is
already fully deterministic: `RuleClassifier` is a pure struct over static
compiled regex, no network call, same input always produces the same output.
This is not a flag to add, it's the existing default. The only thing that
introduces nondeterminism is opting into the LLM fallback explicitly.

## 217. Offline Mode

**(MEASURED, mostly)** `analyze` without `--llm`/`--llm-always` already makes
zero network calls. `--source xcresult` shells out to `xcrun xcresulttool`
locally, also no network. The one thing that isn't offline-safe by
construction today: nothing stops a caller from passing `--llm` on a
disconnected machine, it just fails with `TriageError.claudeAPIError` when
the request can't complete. **(TARGET)** An explicit `--offline` flag that
refuses to attempt the network call at all (fail fast with a clear message
instead of a URLSession timeout) would be a small, high-value addition.

## 218. Performance Budget

**(MEASURED, informal)** Rule classification is sub-millisecond per the
README's own example output (`time: 0ms`). Full `swift test` for the current
76-test suite runs in about 2 seconds on this machine, measured this session.
**(TARGET)** No formal budget exists per category (startup time, parse time
for a large xcresult, sandbox wall-clock). Given `SandboxValidator`'s
dominant cost is a real `swift build` (Section 269 below), that's the one
category that would need an explicit budget and a regression alert before
this went into any shared CI path, since a slow sandbox blocks the pipeline
stage that's waiting on it.

## 219. Memory Discipline

**(MEASURED)** `XCResultParser` and `SandboxValidator` already avoid the
naive "read the whole subprocess output into memory with
`readDataToEndOfFile()` after termination" trap, not for memory reasons but
for the deadlock reason documented in Part A/the project Q&A: a full 64KB
pipe buffer blocks the child while the parent waits on termination. The
`readabilityHandler`-drains-continuously pattern used in both incidentally
also bounds how much unread data can pile up in the pipe at once, which
matters more as log/build output size grows. **(TARGET)** No streaming
xcresult parser exists yet; `XCResultParser.summary()` decodes the entire
JSON document into memory via `JSONDecoder`, which is fine at today's scale
and would need revisiting only if bundle sizes grew enough to matter, not
before.

## 220. Stable Core / Experimental Edge

**(MEASURED)** This line already exists in the actual codebase, not just as
an aspiration: `RuleClassifier`, `FailureFingerprint`, `BuildLogParser`,
`XCResultParser` are the stable, fully deterministic core, unit-tested with
fixed input/output pairs. `ClaudeClassifier`, `PatchGenerator` are the
LLM-touching edge, and both are structured so removing them (unset
`XCTRIAGE_ANTHROPIC_API_KEY`) degrades the tool to the stable core rather
than breaking it. `remediate`'s two `RemediationPolicy` gates and
`SandboxValidator` sit in between: deterministic code that constrains the
edge, which is the right place for them.

## 221. Interface Boundaries

**(MEASURED)** `ClassificationResult`, `FailureSite`, `PatchProposal`,
`RemediationPolicy.Decision`, `SandboxValidator.Result` are all plain
`Sendable` value types that cross every boundary in the current codebase
(classifier to reporter, generator to policy, policy to CLI). No boundary in
the real code passes a live actor reference or a raw `Process` handle across
a module edge; everything crossing a boundary is data.

## 222. Dependency Inversion

**(MEASURED, partial)** `PatchGenerator` and `ClaudeClassifier` depend on
`URLSession`, injected with a real default (`.shared`) and swapped for
`StubURLProtocol` in tests, not a bespoke provider abstraction.
`SandboxValidator` depends on `gitPath`/`swiftPath` strings, same pattern.
**(TARGET)** There is no `ReasoningProvider` protocol abstracting "the LLM"
as a vendor-neutral interface, because there's only ever been one vendor
(Claude) and building that abstraction before a second consumer exists would
be speculative. Section 288's "what would change my mind" applies here: add
it when a second model provider is actually needed, not before.

## 223. Testability Through Interfaces

**(MEASURED)** Every subprocess- or network-touching type in the repo is
tested this way today: point the same init parameter that takes a real
executable path or a real `URLSession` at a fake instead
(`XCResultParserTests.makeFakeXcrun`, `SandboxValidatorTests.makeFakeTool`,
`PatchGeneratorTests.stubbedSession`). No mocking framework anywhere in the
dependency graph. **(TARGET)** The same pattern would extend cleanly to any
future GitHub/Jira/PagerDuty client: inject the base URL or the
`URLSession`, stub at that exact seam, nothing more elaborate.

## 224. Deterministic Replay

**(TARGET)** No replay command exists. If a durable workflow store existed
(Part B), replay would mean: given a `remediation_id`, re-run
`PatchGenerator` and `SandboxValidator` against the exact stored inputs
(same failure site, same file contents, same model version) and diff the
new output against the stored one. Useful for regression-testing prompt
changes and for incident review ("did this remediation behave differently
last week"). Not built because there's no persistent remediation history to
replay yet, only ephemeral CLI runs.

## 225. Time as a Dependency

**(MEASURED, one real instance)** `FlakyTestTracker.cutoffDate()` computes
`Date()` minus a 90-day window directly via `Calendar.current`, with no
injected clock. This is a real, honest gap: `FlakyTestTrackerTests` cannot
currently test window-boundary behavior (a failure exactly 90 days old)
without waiting or mocking `Date` some other way. **(TARGET)** Injecting a
`clock: () -> Date = Date.init` parameter into `FlakyTestTracker.init` would
close this cleanly and is a small, well-scoped next test-quality improvement,
not a redesign.

## 226. Randomness as a Dependency

**(MEASURED)** No randomness exists anywhere in the current codebase's
control flow. `FailureFingerprint` deliberately avoids Swift's randomly
seeded `Hasher` for exactly this reason (documented in the code comment and
in the project Q&A): fingerprints must be stable across process runs, so
SHA256 over normalized input is used instead of anything seeded. If retry
jitter or sampling were added later (Part B/C's backpressure sections), a
seeded generator would be injected the same way the clock would be.

## 227. State-Machine Invariants

**(MEASURED, small)** The real invariant that exists today lives in
`RemediationPolicy` and `SandboxValidator`'s call order in `Remediate.run()`:
eligibility gate before patch generation, patch-allowed gate before sandbox,
sandbox pass before the diff is ever printed. `RemediationPolicyTests` and
`SandboxValidatorTests` pin this ordering by asserting exactly what happens
when an earlier stage fails (`test_validate_stopsAtWorktreeFailureWithoutApplyingOrBuilding`
proves the pipeline stops, not just that it eventually returns false).
**(TARGET)** A named `RemediationState` enum (proposed/eligible/patched/
validated/rejected) doesn't exist yet because there's no persistent
workflow to hold it in; today the "state machine" is just sequential
function calls within one CLI invocation.

## 228. Database Constraints as Correctness Tools

**(MEASURED)** `FlakyTestTracker`'s real SQLite schema uses `NOT NULL` on
`test_name`/`source`/`failed_at` and two indexes (`idx_test`, `idx_time`),
enforced by SQLite itself, not by application-level checks before insert.
**(TARGET)** No `UNIQUE` or `FOREIGN KEY` constraint exists yet because the
schema is a single flat event table with no relationships to enforce; a
Postgres-backed failure history (Part B) would need real
`UNIQUE(fingerprint, occurred_at)`-style constraints for idempotency.

## 229. Optimistic Concurrency

**(TARGET)** Not applicable to the current single-process CLI; there is no
concurrent writer to race against. Becomes relevant only if a shared
workflow store exists (Part B), at which point a `version` column and a
conditional `UPDATE ... WHERE version = ?` would guard against two workers
racing on the same remediation attempt, same pattern as any concurrent
job-queue design.

## 230. Event Ordering

**(TARGET)** No event stream exists today. If one were added (Part B), the
correct ordering guarantee is per-fingerprint, not global: two failures with
different fingerprints have no ordering relationship worth guaranteeing, but
two occurrences of the same fingerprint need to process in arrival order so
the flaky-score/attempt-count logic doesn't race with itself.

## 231. Event Replay

**(TARGET)** Same caveat as 224/230: no event stream exists. If one did,
every consumer touching `FlakyTestTracker`-equivalent state would need to be
idempotent under redelivery, which the current schema already supports for
free: `INSERT INTO flaky_events` on a genuine duplicate delivery just adds
one more row and inflates the score slightly rather than corrupting state,
though a `UNIQUE(build_id, test_name)` constraint would make it truly
idempotent instead of merely tolerant.

## 232. Event Schema Evolution

**(TARGET)** Not applicable yet, no wire schema to evolve besides the CLI's
own JSON output shape. That shape has no `schema_version` field today
**(MEASURED gap)**, a real one to fix cheaply: any consumer piping
`--output json` into another tool has no explicit contract that the shape
won't change between versions.

## 233. Exactly-Once Skepticism

**(MEASURED, already true)** The one place this matters today is
`FlakyTestTracker.record()`, called once per test failure per `analyze`
run. If the same CI job retried the whole `xctriage analyze` invocation
after a transient failure, the tracker would record the failure twice with
no dedup key. `--no-track` exists as an escape hatch but doesn't solve
idempotency, it just opts out of tracking entirely. This is a real,
un-fixed gap worth naming rather than a hypothetical one.

## 234. Database Choice by Access Pattern

**(MEASURED)** SQLite with WAL mode is the actual, deliberate choice for
`FlakyTestTracker`: single-writer-friendly, embedded (no server to run),
appropriate for a local per-developer or per-CI-runner flaky-test history
that doesn't need to be shared across machines. **(TARGET)** A shared,
cross-repo failure history (Part B) would need a real server-backed store
(Postgres) precisely because the access pattern changes from "one machine
reads/writes its own history" to "many CI runners write, one dashboard
reads across all of them."

## 235. PostgreSQL Query Examples

**(TARGET)** No Postgres exists today; these are illustrative queries a
Part B failure-history table would need to support:

```sql
-- last 20 occurrences of a fingerprint
SELECT occurred_at, build_id, branch
FROM failure_occurrences
WHERE fingerprint = $1
ORDER BY occurred_at DESC
LIMIT 20;

-- open remediation attempts for a repository
SELECT id, fingerprint, state, created_at
FROM remediation_attempts
WHERE repository = $1 AND state NOT IN ('resolved', 'rejected')
ORDER BY created_at ASC;

-- remediation acceptance rate by failure category, trailing 30 days
SELECT category,
       COUNT(*) FILTER (WHERE outcome = 'accepted') AS accepted,
       COUNT(*) AS total
FROM remediation_attempts
WHERE created_at > now() - interval '30 days'
GROUP BY category;
```

## 236. Indexing

**(MEASURED)** The two real indexes that exist (`idx_test` on `test_name`,
`idx_time` on `failed_at`) exist because those are the only two columns
`FlakyTestTracker` ever filters or sorts on (`scores(for:)` filters by name
list plus a time cutoff; `topFlaky` groups and orders by count within a time
cutoff). No index exists on `build_id` because nothing queries by it today.
**(TARGET)** A Postgres `failure_occurrences` table (235) would need an
index on `fingerprint` for the first query above and a composite
`(repository, state)` index for the second; neither would be added
speculatively before a query needing them existed.

## 237. Vector Retrieval as Secondary Index

**(TARGET)** No embeddings or vector search exist anywhere in the current
repo. `FailureFingerprint`'s exact SHA256 match is the only retrieval
mechanism today, and it's sufficient for the actual problem
(exact-duplicate detection), which is the point made directly in the project
Q&A: semantic similarity solves a different problem (near-duplicate,
differently-worded failures) that hasn't been shown to be needed yet.

## 238. Search Result Provenance

**(MEASURED, minimal)** `PatchProposal.rationale` and `SandboxValidator.Result.output`
are the current, real provenance for a remediation: the model's stated
reason and the actual build/test transcript that validated it, both
printed in the CLI's proposal header alongside the fingerprint. Nothing
richer (source record ID, retrieval similarity score) exists because there's
no retrieval system yet to have provenance from.

## 239. Staleness

**(TARGET)** Not applicable without a failure-history store to go stale.
Worth flagging for Part B: a fix that worked against Xcode 15 stops being a
valid suggestion once the toolchain moves to Xcode 16 if the root cause was
toolchain-specific, so any future historical-match feature needs a toolchain
compatibility field, not similarity score alone.

## 240. Build and Release Separation

**(MEASURED)** Real and already enforced by the actual CI setup: the
Jenkinsfile and GitHub Actions workflow build, test, and only archive a
release binary on a tag, per the README's own description. There is no
separate "promotion" step because there's no artifact registry yet, a
tagged build IS the release today.

## 241. Release Manifest

**(TARGET)** No manifest exists. Illustrative shape for what a `xctriage`
release manifest would need, matching what the CI pipeline already knows at
build time:

```json
{
  "release_id": "v1.3.0",
  "artifact_digest": "sha256:...",
  "source_commit": "c7cbb0d",
  "swift_version": "6.0",
  "build_run": "gha-run-4821",
  "signature": null
}
```

`signature` is null because no artifact signing exists today; the binary is
downloaded unsigned from GitHub Releases per the current README.

## 242. Rollback Inventory

**(TARGET)** Not applicable to a CLI binary distributed via GitHub Releases;
"rollback" for an end user is "download the previous tagged release," which
GitHub Releases already supports for free by keeping every tagged binary. No
separate retention policy needed at this scale.

## 243. Artifact Garbage Collection

**(TARGET)** Not applicable today for the same reason as 242. Would matter
if release artifacts moved to a self-hosted registry with retention costs.

## 244. Build Failure Taxonomy

**(MEASURED)** This one already exists in real, tested code: the 7
`FailureCategory` cases (`compilation_error`, `test_failure`, `flaky_test`,
`resource_exhaustion`, `infra_failure`, `dependency_failure`, `timeout`) ARE
the build failure taxonomy, backed by 17 real regex rules
(`RuleClassifier.defaultRules`), each mapped to a category with a
`weight`/confidence.

## 245. Infrastructure vs Product Failure

**(MEASURED, partial)** `infra_failure` already exists as a distinct
category from `compilation_error`/`test_failure`, a `simctl boot timeout`
or `xcode-select` error is classified separately from an actual code defect,
by pattern, today. **(TARGET)** What doesn't exist yet is the
cross-failure correlation that would let xctriage say "this isn't one
infra failure, it's 40 repos hitting the same simulator-boot timeout at the
same time," because xctriage today only ever sees one build's log at a time,
with no cross-build view.

## 246. Blast Radius Inference

**(TARGET)** Same gap as 245: no cross-repo view exists. This is explicitly
named as the natural next step in the project Q&A's own "how would you take
this to something Apple could run" answer, not a surprise gap: correlate
failures across repos by toolchain version before triaging each
individually, so one bad Xcode upgrade produces one infrastructure incident
instead of N independent (and possibly N wrong) remediation attempts.

## 247. Incident Correlation

**(TARGET)** Would key on `(fingerprint, environment, time window)` once
cross-build visibility exists (Part B). Today, xctriage's
`FailureFingerprint` already gives the first component of that key for
free; the second and third don't exist yet because there's no store
correlating multiple builds.

## 248. Operational Ownership

**(TARGET)** No ownership model exists in the CLI. `CODEOWNERS`-based
owner resolution for a failing file path is a natural, cheap addition (read
the file, don't build a separate ownership database) but isn't implemented.

## 249. Escalation

**(TARGET)** Today "escalation" is just: the pipeline posts to Slack and
leaves the build red for a human, per the real Jenkinsfile/GHA behavior
described in the README. No unknown-owner tracking or fallback routing
exists because there's no ownership resolution (248) to fail out of yet.

## 250. Human Factors

**(TARGET, illustrative)** What a `remediate`-triggered Slack/PR summary
should contain, matching the shape the real CLI's proposal header already
uses (fingerprint, category, confidence, sandbox result, rationale):

```
xctriage remediation proposal, fingerprint 91d7f3a2b8c04e11

What broke:      CheckoutTests.testRetryAfterTimeout (flaky_test, 0.82 confidence)
Sandbox:         build passed, target test passed
Proposed fix:    NetworkClient.swift, reset request deadline on retry
Files touched:   1 (NetworkClient.swift)
Policy checks:   eligibility PASS, forbidden-path PASS, sandbox PASS
Human action:    review diff, approve or reject
```

This is exactly what the current `remediate` CLI already prints today
**(MEASURED)**, just reframed as a notification payload instead of stdout.

## 251. Explainability Without Chain-of-Thought

**(MEASURED)** This is already the real design, not a target: neither
`ClaudeClassifier` nor `PatchGenerator` ever exposes model reasoning tokens
or an internal thought process. Both are constrained to schema-only JSON
output (category/confidence/summary/suggested_fix for the classifier;
file_path/unified_diff/rationale/confidence for the patch generator);
`rationale` is a required, single-sentence field, not a reasoning transcript.
The CLI's remediation proposal (250) surfaces exactly that: observed facts
(fingerprint, category, confidence), the sandbox's real pass/fail verdict,
and a one-sentence rationale, no hidden reasoning to hide or reveal.

## 252. Auditability Without Surveillance

**(TARGET)** No audit log exists yet, since there's no server-side state to
audit, everything happens in one CLI process. When one does (Part B), the
sensitive actions worth auditing are narrow and already implied by the real
policy gates: who ran `remediate`, what fingerprint, what the two
`RemediationPolicy` decisions were, what the sandbox verdict was. That's a
short, specific list, not "every keystroke" telemetry.

## 253. Separation of Duties

**(MEASURED, structural)** Already true by construction, not by convention:
`PatchGenerator` (the generator) and `RemediationPolicy` (the gate) are
different types with no shared mutable state, and `PatchGenerator` cannot
call into `RemediationPolicy` or vice versa in the actual dependency graph;
the CLI orchestrates both and neither can approve its own output. The human
reviewing the printed diff is a de facto third party the code doesn't and
can't bypass, since `remediate` never calls `git apply` against the real
repo.

## 254. Two-Person Rule for Critical Classes

**(MEASURED, enforced today)** `RemediationPolicy`'s real
`forbiddenPathPrefixes` default (`Sources/XCTriageKit/Classifiers/`,
`Sources/XCTriageKit/Policy/`, `.github/`, `Package.swift`, `Jenkinsfile`)
IS a hard block, not a two-person-review trigger, on the highest-risk
category: the code that constrains automated changes cannot itself be
changed by an automated change. A softer "two human approvals required" tier
for other security-sensitive paths is a **(TARGET)** extension of the same
mechanism, not a new one.

## 255. Risk Classification

**(MEASURED, binary today)** Currently binary via
`RemediationPolicy.allowedCategories` (default: `flakyTest`,
`compilationError` only) and `maxFilesChanged` (default 1), a change is
either eligible or not, there's no LOW/MEDIUM/HIGH/CRITICAL gradient yet.
**(TARGET)** A graduated risk score (files touched, path sensitivity,
category) is a natural evolution of the same two functions
(`isEligibleForRemediation`, `isPatchAllowed`) already in place, not a
rewrite.

## 256. Security-Sensitive Paths

**(MEASURED)** This exists today, just scoped to xctriage's own repo
structure rather than a general pattern language:
`forbiddenPathPrefixes` in `RemediationPolicy`. **(TARGET)** Generalizing to
glob patterns (`Security/**`, `Auth/**`, `**/*credentials*`) for adoption in
other repos is straightforward given the existing `hasPrefix`-based check,
just not built because xctriage has only ever gated its own source tree.

## 257. No Security Downgrade as Remediation

**(TARGET, partially enforced)** No explicit detector for "this diff
disables TLS verification" exists in `PatchGenerator` or
`RemediationPolicy` today; the real enforcement is indirect, via the
single-file/single-attempt cap and the forbidden-path list, plus the sandbox
requiring the target test to actually pass (a patch that disables the check
being tested for would generally fail the sandboxed test run it's supposed
to fix, not pass it). A dedicated pattern check for known security-downgrade
diffs (removing `URLSession` cert pinning, adding `-k`/`--insecure` flags)
is a real, un-built gap worth naming rather than claiming solved.

## 258. No Privacy Downgrade as Remediation

**(TARGET)** Same honest gap as 257: no explicit check exists for "this
diff logs a secret" or "this diff widens data collection." The forbidden-path
list (256) would block a diff to a dedicated privacy-policy file, but
wouldn't catch a one-line `print(user.email)` added inside an otherwise
allowed file. Worth flagging as future work, not glossed over.

## 259. Secure Failure Handling

**(MEASURED)** `TriageError.claudeAPIError(Int, String)` already includes
the raw HTTP response body in its message
(`String(data: data, encoding: .utf8) ?? "no body"` in both
`ClaudeClassifier.post()` and `PatchGenerator.post()`), this is a real,
worth-naming gap: if Claude's API ever returned an error body containing
something sensitive (it wouldn't under normal operation, but the code
doesn't filter it), that string would surface directly to whoever's running
the CLI. Low risk in practice, honest to flag.

## 260. Dependency Security

**(MEASURED)** `Package.resolved` pins exact dependency versions/hashes for
Swift Package Manager, standard SPM behavior, already in place. **(TARGET)**
No SBOM generation or vulnerability scanning of dependencies exists in the
CI pipeline yet; the README describes SAST (Semgrep/CodeQL) and
secret/misconfig scanning (Trivy) but not a dependency CVE scan specifically.

## 261. Dependency Update Strategy

**(TARGET)** No automated dependency-update remediation exists; xctriage's
own `RemediationPolicy` wouldn't allow it anyway under the current
`allowedCategories` (`flakyTest`, `compilationError`), a dependency bump
isn't either of those categories, so it's already structurally excluded from
auto-remediation without a special rule needed.

## 262. Toolchain Provenance

**(MEASURED, partial)** The README states Swift 6.0 and macOS 14+ as
requirements; CI runners record their own Xcode/Swift version implicitly via
the runner image, but xctriage doesn't currently emit a structured
toolchain-provenance record per build. **(TARGET)** would be a small
addition: capture `swift --version` output into the JSON report.

## 263. Toolchain Rollouts

**(TARGET)** Not applicable, xctriage has one fixed CI runner image per
pipeline today, no fleet to roll a toolchain across.

## 264. Detect Toolchain-Induced Failures

**(TARGET)** Directly related to 245/246: this requires cross-build
correlation that doesn't exist yet. Today, an Xcode upgrade that broke every
repo would show up as N separate `infra_failure` or `compilation_error`
classifications with no signal tying them together beyond a human noticing
the pattern manually.

## 265. Build Fleet Architecture

**(TARGET)** Not applicable, xctriage's own CI runs on whatever runner
GitHub Actions/Jenkins provides; xctriage doesn't operate a build fleet
itself, it's a tool that runs on top of one.

## 266. Ephemeral Runner Security

**(MEASURED, adjacent)** The one place this principle is already real is
`SandboxValidator`'s ephemeral `git worktree`, which is created fresh per
validation and torn down in a `defer` block regardless of outcome, the same
"clean state, no persistence" property an ephemeral CI runner would have,
just at the worktree level rather than the machine level.

## 267. macOS-Specific Build Constraints

**(MEASURED)** Directly true and already documented: `XCResultParser`
shells out to `/usr/bin/xcrun`, and the README states macOS 14+ as a hard
requirement. There is no portable, non-macOS path for `.xcresult` parsing
because `xcresulttool` itself doesn't exist off Apple platforms; the
`analyze` subcommand's plain build-log path (no xcresult) is the only part
that could run on Linux CI in principle, untested today.

## 268. Remote Build Execution Direction

**(TARGET)** Not applicable, no remote execution model exists or is
proposed; `SandboxValidator` already runs locally on whatever machine invokes
`remediate`. If sandbox validation needed to run on dedicated hardware
instead of the caller's machine, the natural model is action/inputs/
toolchain/cache-key/result the same as any remote-execution system, but
building this before local sandboxing has a demonstrated bottleneck would be
speculative.

## 269. Performance Regression Detection

**(TARGET)** No baseline-tracking exists. `SandboxValidator`'s dominant cost
(a real `swift build` + `swift test --filter`) is exactly the kind of signal
worth tracking over time once this runs in a real pipeline: a fix whose
sandbox validation suddenly takes 5x longer than the historical average for
that repo is itself a signal worth surfacing, separate from pass/fail.

## 270. Statistical Discipline

**(TARGET)** Related to 269: no rolling baseline or percentile tracking
exists yet, so there's nothing to over-alert on incorrectly, but the
principle to hold going in is the same one used in the flaky-test scoring
that DOES exist (`FlakyTestTracker`'s score is a ratio over a 90-day window,
not a single-run signal), don't flag a regression off one slow build any
more than xctriage flags a test as flaky off one failure.

## 271. Benchmark Integrity

**(MEASURED, honest)** The only performance numbers stated anywhere in this
document set are the ones explicitly measured this session (104 tests, ~2
second full suite run, sub-millisecond rule classification per the README's
own example), no cherry-picked best case, no warm-vs-cold-cache
distinction claimed because it hasn't been measured. Any future benchmark
claim should carry machine/toolchain/run-count exactly like this one does.

## 272. Measured vs Target vs Simulated

**(MEASURED, meta)** This is the labeling convention this entire four-part
document set uses throughout, stated once here explicitly: every concrete
claim is (MEASURED) or (TARGET), with no (SIMULATED) category used anywhere
in Parts A-D because no simulated/demo data has been generated or presented
as real. If a future version of this document set adds load-test or
capacity-estimation output, it must be labeled (SIMULATED) and never
presented unlabeled.

## 273. Cost as a First-Class Engineering Signal

**(MEASURED, partial)** The real, deliberate cost design that exists today:
`ClaudeClassifier` truncates log input to 4,000 characters
(head+tail) before sending to Claude regardless of log size, and both
`ClaudeClassifier` and `PatchGenerator` use ephemeral prompt caching on the
system prompt (`cache_control: ephemeral`) so repeated calls don't re-pay
for the same system prompt tokens. **(TARGET)** No actual token/cost
tracking or per-failure cost metric is instrumented yet; the truncation and
caching are cost-conscious design choices without a measured dollar number
behind them.

## 274. Sustainability Through Efficiency

**(MEASURED)** The fingerprint-before-LLM design (already real, not
proposed) is the concrete instance of this principle: 500 identical
failures from one bad commit produce one fingerprint match and, at most, one
model call for the first occurrence, rather than 500 redundant classifier
calls, because `FailureFingerprint` is computed deterministically and
cheaply (O(1) SHA256) before any network call is considered.

## 275. Deployment Frequency Is Not the Goal by Itself

**(TARGET)** Not directly applicable, xctriage itself has no continuous
deployment pipeline of its own beyond tagged-release binaries (240). The
principle matters for any Part B/C target-architecture proposal involving
auto-remediation reaching production: the goal is safe, correct fixes
landing, not a maximized count of auto-generated PRs.

## 276. Correctness Before Automation

**(MEASURED, this is the actual design)** The real automation ladder in the
existing code is exactly this shape: `analyze` (manual, deterministic, no
automation) came first and remains fully functional standalone; `--llm`
fallback (assisted) is opt-in; `remediate`'s two-gate policy plus sandbox
(automated-with-verification) only proposes, never auto-applies; nothing in
the current CI pipeline auto-merges anything beyond the single, narrow
`flaky_test` retry case described in the README. Each rung was only added
once the rung below it was solid and tested.

## 277. Operational Learning Loop

**(TARGET)** No incident/failure history exists yet to learn from
systematically; today, learning happens the way it does in any small
project, by the person maintaining it noticing a gap and fixing it (exactly
how `SandboxValidator` and the `remediate` subcommand came to exist as the
next items in a previously-recorded 7-task plan). A formal loop (every
incident produces a tracked corrective action) is proposed for Part B once
there's a real incident stream to close the loop on.

## 278. Post-Incident Review

**(TARGET)** No incidents have occurred (no production deployment exists to
have an incident in). Template proposed for future use, kept intentionally
lightweight: Impact, Timeline, Detection, Root Cause, Contributing Factors,
What Went Well, What Didn't, Corrective Actions, How We Prevent Recurrence.

## 279. Corrective Action Ownership

**(TARGET)** Same gap as 278, not applicable without incidents to generate
corrective actions from. Principle to hold: every corrective action gets an
owner and a status, or it's documentation, not remediation.

## 280. README Product Principle

**(MEASURED, close)** The real README already opens with a similar spirit
("From 'xcodebuild failed' to root cause + fix in under a second") and its
own explicit AI-safety line ("the LLM only picks the failure category, it
never picks the action"). **(TARGET)** The four-line framing this document
set proposes (private by design / secure by default / deterministic at the
core / AI only where reasoning adds value) is not literally in the current
README yet; it's a proposed refinement of the message already there, not a
new message.

## 281. README Privacy Visual

**(TARGET)** No privacy-specific diagram exists in the current README. One
is proposed showing the real, existing shape (BuildLogParser/XCResultParser
extract locally, only a 4,000-char truncated window ever leaves the
machine, and only when `--llm` is explicitly passed) since that shape is
already true today, just not diagrammed.

## 282. README Security Visual

**(TARGET)** No such diagram exists yet. Proposed shape mirrors the real
`remediate` pipeline already built: proposal, two policy gates, sandbox,
human approval, with the explicit callout "no reasoning model has a direct
production write path," which is already true of the actual code
(`remediate` never calls `git apply` against the real repo).

## 283. README Build Visual

**(TARGET)** No such diagram exists. Proposed shape matches the real
Jenkinsfile/GitHub Actions stage order stated in the current README:
resolve, lint, SAST, dependency/secret scan, build, test, auto-remediate,
archive-on-tag.

## 284. README Closed-Loop Visual

**(TARGET)** No such diagram exists. The honest current loop is shorter
than the proposed DETECT→UNDERSTAND→FIX→PROVE→REVIEW→DEPLOY→OBSERVE→
VERIFY→LEARN cycle: today it's DETECT→UNDERSTAND→FIX→PROVE→REVIEW, full
stop, because DEPLOY/OBSERVE/VERIFY/LEARN all depend on Part B/C
infrastructure (a workflow store, a deployment target) that doesn't exist.
Diagramming the full aspirational loop should visually distinguish the
built half from the proposed half, not present both as equally real.

## 285. Documentation Reading Paths

**(MEASURED, this document set)** This is what the README plus Parts A-D
already provide: a reader wanting the 30-second version reads the README's
hero section and usage examples; a reader wanting build/security/
reliability/AI depth reads the relevant target-architecture part. No
job-title or company framing appears in these documents by design.

## 286. Layered Answers in Documentation

**(MEASURED, demonstrated)** This document (Part D) does the
30-second/deep-dive split at the section level via the MEASURED/TARGET tag
itself, which functions as the layering signal: MEASURED sections are
already the "5 minute" answer, TARGET sections are the "deep dive into
where this would go."

## 287. Design-Review Questions at the End of Each Document

**(MEASURED, structural precedent)** Section 306 below (Architecture
Challenge Matrix) folds this pattern in directly: concern mapped to
mechanism, for both real and proposed parts of the system.

## 288. Alternative Design Section

**(MEASURED, one real instance)** `FailureFingerprint.swift` already
states this inline as a code comment: SHA256 was chosen over Swift's
`Hasher` because `Hasher` is randomly seeded per process (by design, to
resist hash-flooding), which breaks the requirement that the same failure
produce the same fingerprint across separate CI runs. The comment also
names what would justify reconsidering the truncation length: bump
`.prefix(16)` to `.prefix(32)` if collision math ever mattered at real
scale. Every TARGET proposal in Parts A-D that names a real alternative
follows this same shape.

## 289. "What Would Change My Mind?"

**(MEASURED, one real instance, generalized here)** Already true for the
fingerprint-length decision: revisit `.prefix(16)` only if fingerprint
volume approaches 2^32 distinct signatures. Generalizing across this
document set: adopt a `ReasoningProvider` abstraction (Section 206) when a
second model vendor is needed; adopt container/microVM sandbox isolation
(Part C) when multi-tenant untrusted patches are in scope, not before,
since today's git-worktree isolation is an honestly-stated, deliberate
tradeoff for a single-repo, single-user tool.

## 290. Deep-Dive Question Bank for the Architecture Itself

**(MEASURED, this exists)** The Q&A style used throughout Parts A-D (Swift/
Concurrency, Algorithms/Data Modeling, Safety/Policy Architecture, CI/CD &
Testing Philosophy) already forms this question bank, organized by the same
categories this section asks for, grounded in real code rather than a
generic template.

## 291. Implementation Notes Beside Architecture

**(MEASURED, this is the discipline this whole document tries to hold)**
Every section above that makes a MEASURED claim names the actual file/type
(`RemediationPolicy.forbiddenPathPrefixes`, `FlakyTestTracker.cutoffDate()`,
`SandboxValidator`'s `defer` block) rather than asserting the property in
the abstract. That's the concrete version of "secrets are secure" versus
"the credential is short-lived and repo-scoped" the source spec asks for,
applied consistently rather than as one example.

## 292. Code Should Demonstrate the Claims

**(MEASURED)** This is directly true and directly checkable today, not
aspirational: `RemediationPolicyTests` has 12 cases pinning exact denial
reasons for exact inputs (`test_isPatchAllowed_deniesForbiddenClassifierPath`
asserts the reason string contains "forbidden", not just that the decision
is `.denied`). `SandboxValidatorTests` has 5 cases proving the pipeline
actually stops at the first failed stage (`test_validate_stopsAtApplyFailureWithoutBuilding`
proves `buildSucceeded` is false without a build ever having been attempted,
by construction of the fake tool's exit codes). If this document claims
"the model can't touch its own guardrails," that claim is backed by a
passing test today, not just a design intention.

## 293. Security Tests

**(MEASURED, partial)** `RemediationPolicyTests` covers forbidden-path
rejection (Classifiers/, .github/workflows/, Package.swift) and
file-count-cap rejection, which are real security-relevant tests today.
**(TARGET, honest gaps)** Not yet covered by any test: prompt injection via
a source file's comments (named as an open gap in the project Q&A's own
tradeoffs table), unauthorized repository access (not applicable yet, no
multi-repo access exists), sandbox escape (not applicable at the current
git-worktree isolation level, no stronger boundary to test escaping).

## 294. Privacy Tests

**(TARGET)** No privacy-specific test exists today because there's no
persistence layer or cross-boundary data flow to test for leakage beyond
"does the 4,000-char truncation window actually truncate" (which is
implicitly exercised by `ClaudeClassifierTests`/`PatchGeneratorTests`'
stubbed-response tests, though not asserted as a privacy property
specifically). Worth adding as an explicit assertion, not currently present.

## 295. Security and Privacy Dashboard

**(TARGET)** No dashboard or metrics emission exists; there's no server
process to emit metrics from. `redactions_total`,
`context_policy_denials_total`, and similar counters are Part B/C proposals
contingent on a persistent service existing to hold them.

## 296. Security Review Before Increasing Autonomy

**(MEASURED, principle already followed informally)** The real evolution of
this codebase already followed this discipline without a formal gate
forcing it: fingerprinting and policy shipped and were fully tested before
`PatchGenerator` was wired to actually call an LLM, and `PatchGenerator`
shipped and was tested before `SandboxValidator` existed to validate its
output, and the CLI (`remediate`) only wires all of them together, with the
sandbox gate, after all three were independently solid. **(TARGET)** No
formal "N successful shadow-mode runs required before Level N+1" gate is
codified yet since there's no shadow-mode telemetry to gate on, but the
sequencing discipline itself is real, not aspirational.

## 297. Privacy Review Before Increasing Context Access

**(MEASURED, currently minimal by construction)** Today's context sent to
the model is already minimal by default: `PatchGenerator` sends one file's
contents (truncated at 6,000 characters) plus the specific failure evidence
for that file, never the whole repository. **(TARGET)** No cross-repo
retrieval or longer-retention context exists to review, and the principle
going in is that any future increase to what a model sees (broader file
access, longer prompt history) should require the same kind of explicit,
justified change this document tries to model: state what's being added, why
the narrower version was insufficient, and what the new blast radius is.

## 298. Principle: Processing Location Is a Security Decision

**(MEASURED, already the real design)** `BuildLogParser`/`XCResultParser`/
`FailureFingerprint`/`RuleClassifier` all run entirely locally, on the
machine invoking the CLI, with zero network calls. Processing only moves
outward (to Claude's API) at one explicit point (`ClaudeClassifier`/
`PatchGenerator`), gated by an explicit flag or an explicit env var, never
implicitly.

## 299. Principle: Centralization Has Privacy Cost

**(TARGET)** Not yet a live tradeoff, there's no centralized store to weigh
against per-machine `FlakyTestTracker` SQLite files. Worth stating as a
constraint going into Part B design: a shared cross-repo failure database is
a bigger aggregation target than N independent local SQLite files, and that
cost should be weighed explicitly against the correlation benefits (245/246)
it would enable, not assumed to be free.

## 300. Principle: Metadata Can Be Sensitive Too

**(TARGET)** Directly relevant to any Part B design: repository names, test
names, and failure frequency data are not "just metadata" free of access
control concerns even if file contents and secrets are well-redacted. No
access-control model exists yet because no shared store exists yet to
control access to.

## 301. Principle: Great Security Should Not Destroy Developer Experience

**(MEASURED)** The real `remediate` CLI already follows this: a policy
denial prints a specific, actionable reason (`"path Sources/XCTriageKit/Policy/RemediationPolicy.swift
is forbidden (Sources/XCTriageKit/Policy/)"`), not a bare exit code, per
`RemediationPolicyTests`'s exact-reason-string assertions.

## 302. Principle: Privacy Should Not Require Trust in the Model

**(MEASURED)** The real enforcement mechanism for "the model can't touch
its own guardrails" is `RemediationPolicy.isPatchAllowed`, a deterministic
post-hoc check on the model's actual diff output, not a system-prompt
instruction the model is trusted to follow. The system prompt (in
`PatchGenerator`) does ask for a single-file fix, but the enforcement is the
policy check afterward, not the request beforehand.

## 303. Principle: Security Should Survive Model Failure

**(MEASURED)** Directly demonstrated by the real error handling: a
malformed Claude response (`TriageError.parseError`), a non-200 API
response (`TriageError.claudeAPIError`), or a markdown-fenced/garbled JSON
body are all handled by throwing a typed error rather than proceeding with
a best-effort guess, per `PatchGeneratorTests`'s
`test_proposePatch_throwsOnNonJSONResponseBody` and
`test_proposePatch_throwsOnHTTPErrorStatus`. A confused or hallucinating
model output never silently becomes a patch proposal, it fails the parse
and the CLI run stops.

## 304. Principle: Quality Includes Failure Behavior

**(MEASURED, this is the whole point of this document's tagging
convention)** Every honestly-stated gap in Parts A-D (no clock injection in
`FlakyTestTracker`, no prompt-injection test, no dependency CVE scan) is a
deliberate demonstration of this principle rather than a thing hidden from
the review: stating what's unmeasured and how it fails today is a stronger
signal of engineering judgment than claiming a broader scope of "done" than
the code actually supports.

## 305. Engineering Review Dimensions

Honest qualitative scoring of the current real repo, not the target
architecture:

| Dimension | Strength | Weakness | Next improvement |
|---|---|---|---|
| Correctness | 76 passing tests, deterministic core fully covered | No fuzz testing on parsers | Fuzz `BuildLogParser`/`XCResultParser` on malformed input |
| Simplicity | No infra beyond a Swift package + SQLite file | N/A at this scale | Keep resisting infra additions until a real bottleneck forces one |
| Reliability | Sandbox always tears down via `defer`, even on failure | No injected clock, no retry/backoff on Claude calls | Add clock injection (225), backoff on transient API errors |
| Security | Two real, tested policy gates around the one write-capable path | No prompt-injection test, no dependency CVE scan | Add both (293) |
| Privacy | Context sent to the model is minimal and truncated by construction | No explicit test asserting the truncation boundary | Add an explicit privacy test (294) |
| Performance | Rule path is sub-millisecond, no perf regression yet possible at this scale | No formal budget or baseline tracking | Track sandbox wall-clock once run in a real pipeline (269) |
| Operability | CLI output is quiet, predictable, scriptable | No structured logging, no correlation ID (no multi-process flow yet to correlate) | Add once Part B infra exists, not before |
| Developer Experience | Clear exit code for policy denial, specific reasons in output | No `xctriage init`/config validation yet | Natural next CLI ergonomics addition |
| Scalability | N/A, single-process CLI, no scale target claimed | N/A | Revisit only if adopted beyond one repo |
| Cost | Truncation + prompt caching are real, deliberate cost controls | No measured dollar cost | Instrument token/cost tracking if usage grows |
| Testability | Consistent executable-path/URLSession injection pattern throughout | FlakyTestTracker's time dependency isn't injected | Fix the one real gap (225) |
| Auditability | Denial reasons are specific and test-pinned | No audit log, no server-side state to audit yet | Add once Part B workflow store exists |
| Portability | Core parsing is Swift/Foundation only | xcresult path is hard macOS-only, by necessity of `xcresulttool` | Document the boundary clearly (already done, 267) |

## 306. Architecture Challenge Matrix

| Concern | Mechanism | Status |
|---|---|---|
| Duplicate failure floods the classifier/model | `FailureFingerprint` (SHA256, normalized) | (MEASURED) |
| A fix that "looks safe" but touches guardrail code | `RemediationPolicy.forbiddenPathPrefixes` | (MEASURED) |
| Model ignores "one file only" instruction | `RemediationPolicy.isPatchAllowed` file-count cap | (MEASURED) |
| Model's patch doesn't actually fix anything | `SandboxValidator` real `swift build` + `swift test --filter` | (MEASURED) |
| Sandbox run leaks disk on failure | `defer`-scoped `git worktree remove --force` | (MEASURED) |
| Deadlock draining subprocess output | continuous `readabilityHandler` drain (XCResultParser, SandboxValidator) | (MEASURED) |
| Fingerprint instability across process runs | SHA256 instead of seeded `Hasher` | (MEASURED) |
| Malformed/hallucinated model JSON | typed `TriageError.parseError`, no silent best-effort guess | (MEASURED) |
| Non-200 Claude API response | typed `TriageError.claudeAPIError(code, body)` | (MEASURED) |
| Untested time-window boundary in flaky scoring | no clock injection yet | (TARGET gap, named) |
| Retry of a failed `analyze` double-recording a flaky event | no idempotency key on `FlakyTestTracker.record` | (TARGET gap, named) |
| Prompt injection via source-file comments | no dedicated test/detector yet | (TARGET gap, named) |
| One bad toolchain upgrade looks like N unrelated failures | no cross-repo correlation yet | (TARGET, Part B) |
| Model context growing beyond what's needed | 4,000/6,000-char truncation caps, single-file context | (MEASURED) |
| LLM outage | deterministic `RuleClassifier` path degrades gracefully with no code change needed | (MEASURED) |
| Untrusted multi-tenant sandbox escape | git-worktree isolation only, no container/microVM | (TARGET gap, named, Part C) |

## 307. Final Architecture Philosophy

This four-part document set (Parts A-D) exists to answer one question
honestly at every layer: what is real in `xctriage` today, and what would a
principled next step look like if this had to run at real scale, for real
teams, with real security and privacy stakes. The discipline held
throughout, not just in this closing section, is: state the mechanism, not
the aspiration; test the claim, not just assert it; name the gap instead of
implying it's solved. What's actually real and tested today is small and
deliberately so: a deterministic 17-rule classifier, an LLM fallback that
only activates below a confidence threshold and only ever sees a truncated
window, a fingerprint that survives process restarts because it doesn't
depend on Swift's seeded hasher, two policy gates that a model cannot argue
its way past because they run as plain, tested Swift code, and a sandbox
that proves a fix with a real compiler and a real test run instead of taking
the model's word for it. Everything proposed across Parts A-D beyond that
(event buses, Postgres, build fleets, cross-repo correlation, container
isolation, audit dashboards) is there because a Staff-level design
conversation should be able to go there, not because xctriage claims to have
built it. The same rule that gates the code (`RemediationPolicy`: the model
proposes, deterministic code decides) is the rule this document tries to
follow about itself: describe what's proposed as proposed, and let the 76
passing tests speak for what's real.

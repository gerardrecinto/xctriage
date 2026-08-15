# xctriage

![CI](https://github.com/gerardrecinto/xctriage/actions/workflows/ci.yml/badge.svg)
![Release](https://github.com/gerardrecinto/xctriage/actions/workflows/release.yml/badge.svg)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?logo=apple&logoColor=white)
![Tests](https://img.shields.io/badge/Tests-47%20passed-brightgreen)
![License](https://img.shields.io/badge/License-MIT-lightgrey)
![Claude](https://img.shields.io/badge/Claude-Sonnet_5-orange?logo=anthropic&logoColor=white)

![xctriage logo](docs/assets/logo.svg)

> From "xcodebuild failed" to root cause + fix in under a second.

Swift 6 command-line tool for AI-powered CI failure analysis on Apple platforms. Parses xcodebuild console output and `.xcresult` bundles. Rule-based classifier with Claude fallback via `URLSession`. Actor-based SQLite flaky test tracker with 90-day recurrence scoring.

Built to demonstrate what "passion for the CI user experience on Apple's platform" looks like in practice: native Swift, native tooling, native concurrency model.

![demo](docs/assets/demo.gif)

---

## What it looks like in practice

```
$ xctriage analyze xcbuild.log --source xcodebuild --build-id ios27-5512

────────────────────────────────────────────────────────────
  xctriage
────────────────────────────────────────────────────────────
  ✗  COMPILATION ERROR
  build:  ios27-5512
  source: xcodebuild
  lines:  18
  time:   0ms

  CONFIDENCE
  ██████████████████░░ 92%

  ROOT CAUSE
  Swift/ObjC unresolved symbol or type error

  SUGGESTED FIX
  Check import statements and module visibility. Run
  `xcodebuild -showBuildSettings` to verify framework search paths.

  FAILURE SITES
  MediaDecoder.swift:142:17
    use of unresolved identifier 'AVAssetTrackSegment'
  MediaDecoder.swift:156:9
    cannot convert value of type 'CMTime' to specified type 'Double'
  AudioBufferProcessor.swift:89:22
    value of type 'AVAudioFormat' has no member 'channelCapacity'

  (analysis: rule-based)
────────────────────────────────────────────────────────────
```

Add `--llm` to fall back to Claude when rule confidence drops below 0.60:

```
$ export XCTRIAGE_ANTHROPIC_API_KEY=sk-ant-...
$ xctriage analyze xcbuild.log --source xcodebuild --llm
```

---

## Architecture

```
xcodebuild / xcresult bundle / CI log
            │
            ▼
┌─────────────────────────────────────────────────────────┐
│                        xctriage                         │
│                                                         │
│  ┌────────────────┐   ┌────────────────────────────┐    │
│  │  BuildLogParser│   │   XCResultParser (actor)   │    │
│  │  NSRegex rules │   │   xcrun xcresulttool wrap  │    │
│  │  Level detect  │   │   Codable JSON decode      │    │
│  └───────┬────────┘   └───────────┬────────────────┘    │
│          └──────────┬─────────────┘                     │
│                     ▼                                   │
│  ┌──────────────────────────────────────────────┐       │
│  │            RuleClassifier (struct)            │       │
│  │  17 NSRegularExpression rules                 │       │
│  │  7 categories · sub-millisecond · no network │       │
│  └───────────────────┬──────────────────────────┘       │
│                      │ confidence < 0.60 AND --llm       │
│                      ▼                                   │
│  ┌──────────────────────────────────────────────┐       │
│  │          ClaudeClassifier (actor)             │       │
│  │  URLSession POST to Claude API               │       │
│  │  Ephemeral prompt cache · Codable response   │       │
│  └───────────────────┬──────────────────────────┘       │
│                      │                                   │
│                      ▼                                   │
│  ┌──────────────────────────────────────────────┐       │
│  │         FlakyTestTracker (actor)              │       │
│  │  SQLite WAL · 90-day window                  │       │
│  │  score > 0.70 → quarantine candidate         │       │
│  └───────────────────┬──────────────────────────┘       │
│                      │                                   │
│          ┌───────────┴──────────────┐                   │
│          ▼           ▼              ▼                    │
│     Terminal        JSON           Slack                 │
│     (ANSI)       (Codable)      (URLSession)             │
└─────────────────────────────────────────────────────────┘
```

---

## CI Sources

| Source | Flag | What it parses |
|---|---|---|
| xcodebuild | `--source xcodebuild` | `.swift`/`.m` file:line:col errors, XCTest case failures, linker errors, `** BUILD FAILED **` |
| xcresult bundle | `--input build.xcresult` | `xcrun xcresulttool` JSON: build errors, test failures |
| GitHub Actions | `--source github` | `##[error]` annotations, `::error file=` |
| Generic | `--source generic` | Rule-based fallback |

---

## Failure Categories

| Category | Patterns (17 total) | Apple CI example |
|---|---|---|
| `compilation_error` | unresolved identifier, type mismatch, linker, code sign | `use of unresolved identifier 'AVAssetTrackSegment'` |
| `test_failure` | XCTest case failed, XCTAssert failure, `** TEST FAILED **` | `Test Case '-[MediaTests testBitIdentical]' failed (2.3s)` |
| `flaky_test` | intermittent, async timeout, connection-in-test | `async operation did not complete within 2 seconds` |
| `resource_exhaustion` | OOM, Killed:9, disk full, DerivedData | `No space left on device`, memory pressure |
| `infra_failure` | xcode-select error, simctl boot timeout, git LFS | `simctl boot failed: timeout` |
| `dependency_failure` | SPM resolve failed, CocoaPods error | `swift package resolve failed: package not found` |
| `timeout` | build timeout, signal KILL | `Build timed out after 3600 seconds` |

---

## Swift 6 Concepts Demonstrated

Rather than a feature checklist, here is how each concept appears in the actual code:

**`actor` for concurrent state**
- `ClaudeClassifier`: actor protects concurrent URLSession calls; no data races possible on API key / model config
- `XCResultParser`: actor wraps `Process` subprocess execution; multiple callers can't interleave xcresulttool spawns
- `FlakyTestTracker`: actor serializes all SQLite reads/writes; replaces NSLock or DispatchQueue

**`async/await` with `withCheckedThrowingContinuation`**
- `XCResultParser.run()`: converts `Process.terminationHandler` callback to async; no nested completion handlers
- `ClaudeClassifier.post()`: `URLSession.data(for:)` is async; entire network path is await-able

**Typed `throws` / custom `Error` enum**
- `TriageError: Error, Sendable`: all failure modes are named cases: `.xcresultToolFailed(Int32, String)`, `.claudeAPIError(Int, String)`, `.fileNotFound(String)`, `.parseError(String)`

**`Sendable` throughout**
- All model types are `Sendable` value types (`struct`, `enum`)
- `DBHandle: @unchecked Sendable`: wraps `OpaquePointer` so actor `deinit` can close SQLite without violation

**`Codable` for xcresult JSON**
- `XCResultSummary`, `XCResultAction`, `XCResultIssueSummary`: decode `xcresulttool` output with custom `CodingKeys` for Apple's `_value` nested structure

**`NSRegularExpression` at module level**
- All 17 patterns compiled once in `BuildLogParser` static constants: avoids per-call recompilation across every build log line

**`CommandConfiguration` + `AsyncParsableCommand`**
- `swift-argument-parser` integration for `analyze` and `flaky` subcommands with typed flags and options

---

## CI/CD Pipelines

The included `Jenkinsfile` and `.github/workflows/ci.yml` both run xctriage on their own build output: a self-triaging pipeline that classifies its own failures instead of leaving that to whoever's on call.

Both pipelines run the same checks in the same order: resolve, lint (SwiftLint), SAST (Semgrep in Jenkins, CodeQL in GitHub Actions since CodeQL isn't practical to self-host without a GHAS license), dependency/secret/misconfig scan (Trivy), build, test, auto-remediate, then archive a release binary on a tag.

### Auto-Remediation

Both pipelines classify test failures with Claude before deciding what to do about them, and both apply the same rule: **the LLM only picks the failure category, it never picks the action.**

- A `flaky_test` verdict at 0.75+ confidence gets one automatic retry. If the retry passes, the build goes green and nobody gets paged for a flake.
- A `compilation_error` verdict gets a policy-gated remediation attempt instead: `xctriage remediate` fingerprints the failure, re-checks it against `RemediationPolicy` (category allowlist, confidence floor, forbidden paths), asks Claude for exactly one single-file unified diff, and proves that diff by applying it inside an isolated `git worktree` and actually running `swift build` + `swift test` there. If policy or the sandbox rejects it — wrong shape, too many files, still doesn't build, still doesn't pass — the command exits non-zero and the pipeline falls through to the same Slack notification as any other unhandled category. Nothing here is ever applied to the working tree or opened as a PR; a passing proposal is archived as a build artifact for a human to read and apply by hand.
- Every other category (dependency failure, OOM, timeout, infra failure) has no safe auto-fix, so the pipeline posts the LLM's suggested fix to Slack and leaves the build failed for a human.
- The flaky retry only ever happens once, and the remediation attempt only ever proposes, never applies. There's no loop, no escalating retry count, and category eligibility is enforced by `RemediationPolicy` in code, not by pipeline logic trusting the model's word for it.

**Jenkinsfile** (`stage('Auto-Remediate (LLM)')`):

```groovy
if (category == 'flaky_test' && confidence >= threshold) {
    sh 'swift test --enable-code-coverage 2>&1 | tee "${TEST_LOG}"'
    currentBuild.result = 'SUCCESS'
} else if (category == 'compilation_error') {
    def status = sh(script: '"${XCTRIAGE_BIN}" remediate "${TEST_LOG}" --source "${CI_SOURCE}" --repo-root "${WORKSPACE}" --out "${REMEDIATION_DIFF}"', returnStatus: true)
    if (status == 0) {
        archiveArtifacts artifacts: "${REMEDIATION_DIFF}", allowEmptyArchive: true
    }
    sh '"${XCTRIAGE_BIN}" analyze "${TEST_LOG}" --source "${CI_SOURCE}" --llm --output slack'
} else {
    sh '"${XCTRIAGE_BIN}" analyze "${TEST_LOG}" --source "${CI_SOURCE}" --llm --output slack'
}
```

**GitHub Actions** (`.github/workflows/ci.yml`):

```yaml
- name: "Auto-Remediate: retry flaky test"
  if: >
    steps.test.outcome == 'failure' &&
    steps.classify.outputs.category == 'flaky_test' &&
    fromJSON(steps.classify.outputs.confidence) >= fromJSON(env.FLAKY_CONFIDENCE_THRESHOLD)
  run: swift test 2>&1 | tee test.log

- name: "Auto-Remediate: propose sandboxed patch (compilation_error)"
  id: propose_patch
  if: >
    steps.test.outcome == 'failure' &&
    steps.retry.outcome != 'success' &&
    steps.classify.outputs.category == 'compilation_error'
  continue-on-error: true
  run: "$XCTRIAGE_BIN" remediate "$TEST_LOG" --source "$CI_SOURCE" --repo-root . --out "$REMEDIATION_DIFF"
```

Nothing above is an inline literal buried in a step: the confidence threshold, log paths, xctriage binary path, and Trivy severity are all named pipeline variables (Jenkins build parameters and `environment {}` entries; GitHub Actions job-level `env:`), and the agent label / credential IDs are controller-level overrides (`env.XCTRIAGE_AGENT_LABEL`, `env.XCTRIAGE_ANTHROPIC_CREDENTIAL_ID`, `env.XCTRIAGE_SLACK_CREDENTIAL_ID`) rather than build parameters, since those pick *where* and *as whom* the pipeline runs and shouldn't be settable by whoever triggers a build.

---

## Where this could go

Everything above is what runs today. `docs/architecture/` has a four-part design review of what a larger version of this project could look like: an agentic remediation pipeline coordinating multiple specialized agents over an Agent-to-Agent (A2A) protocol, continuous deployment with GitOps and canary rollout, a formal privacy/security threat model, and platform-scale operations.

It's written as a proposal, not a changelog. Every claim in it is tagged `(MEASURED)` when it's true of the code in this repo today, or `(TARGET)` when it's a design goal with nothing built behind it yet. That distinction is the whole point of the document: it exists to be clear about the gap between what's shipped and what's proposed, not to blur it.

- [Part A — Agentic Architecture & Auto-Remediation](docs/architecture/PART_A_AGENTIC_ARCHITECTURE_SECTIONS_1-33.md)
- [Part B — Continuous Deployment & DevOps System Design](docs/architecture/PART_B_DEVOPS_SYSTEM_DESIGN_SECTIONS_34-114.md)
- [Part C — Privacy, Security & Reliability](docs/architecture/PART_C_PRIVACY_SECURITY_PHILOSOPHY_SECTIONS_115-210.md)
- [Part D — Product, Operations & Final Review](docs/architecture/PART_D_PRODUCT_OPERATIONS_SECTIONS_211-307.md)

---

## Install

### Download binary (macOS)

Download the latest `xctriage` binary from [Releases](https://github.com/gerardrecinto/xctriage/releases):

```bash
curl -L https://github.com/gerardrecinto/xctriage/releases/latest/download/xctriage -o xctriage
chmod +x xctriage
mv xctriage /usr/local/bin/xctriage
```

### Build from source

```bash
git clone https://github.com/gerardrecinto/xctriage.git
cd xctriage
swift build -c release
cp .build/release/xctriage /usr/local/bin/
```

---

## Usage

```bash
# Analyze xcodebuild log
xctriage analyze xcbuild.log --source xcodebuild

# Analyze xcresult bundle
xctriage analyze build.xcresult

# Read from stdin (pipe from xcodebuild)
xcodebuild test -scheme MyApp 2>&1 | tee build.log | xctriage analyze - --source xcodebuild

# Claude fallback when confidence < 0.60
export XCTRIAGE_ANTHROPIC_API_KEY=sk-ant-...
xctriage analyze xcbuild.log --source xcodebuild --llm

# Always use Claude
xctriage analyze xcbuild.log --source xcodebuild --llm-always

# JSON output (pipe to jq, Jira, etc.)
xctriage analyze xcbuild.log --source xcodebuild --output json | jq .classification

# Post to Slack
xctriage analyze xcbuild.log --source xcodebuild \
  --output slack --slack-webhook https://hooks.slack.com/...

# Show top flaky tests
xctriage flaky --n 20

# Exit with code 1 on failure: use in CI pipelines to gate merges
xctriage analyze xcbuild.log --source xcodebuild --exit-code
```

### CI gate mode with `--exit-code`

`--exit-code` returns exit code 1 when a failure is detected. Use it to block a pipeline stage on a real build failure:

```bash
# In a Jenkinsfile post-build step
xctriage analyze build.log --source xcodebuild --exit-code

# In a GitHub Actions step
- run: xctriage analyze build.log --source xcodebuild --exit-code
```

---

## Tests

```bash
swift test                          # 22 tests
swift test --enable-code-coverage   # with coverage
swift build -c release              # build binary
bash scripts/make_demo.sh           # run demo fixtures
```

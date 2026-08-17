# High-Level Architecture

One diagram, drawn at the same depth as a system-design interview whiteboard: a shape legend, an explicit reason for every split in the flow, and a decision diamond at every real branch — not just boxes connected by arrows. Two flows, not one, because CI and CD are different failure domains with different owners (see `docs/adr/ADR-007-no-implemented-continuous-deployment.md`): the CI flow below is **(MEASURED)** — it's what `.github/workflows/ci.yml` and the `remediate` CLI subcommand actually do today. The CD flow is **(TARGET)** — the design `docs/architecture/PART_B` lays out in full, none of it provisioned. Conflating the two would misrepresent what's real, which is exactly what `docs/architecture/WHAT_I_DID_NOT_BUILD.md` exists to prevent.

## Shape legend

| Shape | Means | Example from this design |
|---|---|---|
| Rectangle `[ ]` | An ongoing process step — work happens here, no branch | `swift build`, `RemediationPolicy.isEligibleForRemediation`, `SandboxValidator.validate` |
| Diamond `< >` | A real yes/no decision, always exactly two exits | `category eligible?`, `sandbox passed?`, `already has a PR?` |
| Circle `( )`, unlabeled | A true start or a true dead end — nothing follows it on this diagram | `commit pushed` (start); `Foundation.exit(4)` (dead end) |
| Circle `( X )`, labeled | The flow continues on a different diagram, not the next box down | The draft-PR handoff from the CI flow to the CD flow below |

If a shape doesn't branch and doesn't end the flow, it's a rectangle. If it's a real fork, it's a diamond. A box drawn where a diamond belongs hides a decision from whoever's reading it — same rule either diagram.

---

## Flow A: CI — commit to draft PR **(MEASURED)**

Every box below is a real step in `.github/workflows/ci.yml` or a real method call in `Sources/XCTriageKit`. Nothing here is aspirational.

```
                    ( commit pushed to main or a PR )
                                |
                                v
                   [ swift build -c release ]
                                |
                    < build succeeded? >------No------> [ Self-triage: build
                                |                          failure ] --> ( fail job )
                               Yes
                                |
                                v
                       [ swift test ]
                                |
                    < tests all passed? >
                        |              |
                       Yes             No
                        |               |
                        v               v
              ( CI job green )   [ RuleClassifier.classify ]
                                    (17 rules, 7 categories,
                                     deterministic, no LLM —
                                     ClaudeClassifier only
                                     fires below 0.60 confidence)
                                          |
                                          v
                              < category? >
                          ______/    |     \______
                         /           |            \
                  flaky_test   compilation_error   other 6 categories
                         |           |                    |
                         v           v                    v
                  [ retry once, ]  [ FailureFingerprint  [ notify: no safe
                  [ swift test  ]  [   (category+site,     auto-fix path ]
                  [ again       ]  [    SHA256, 16 hex) ]        |
                         |           |                          v
                         v           v                   ( fail job, human
                  ( pass/fail,   [ RemediationPolicy.               triages by hand )
                   report only,  [  isEligibleForRemediation ]
                   no LLM call ) [  (category allowlist,
                                 [   confidence floor,
                                 [   attempt limit) ]
                                          |
                                  < eligible? >------No-----> [ transition:
                                          |                     .policyRejected ]
                                         Yes                           |
                                          |                            v
                                          v                   ( fail job, blocked
                          [ FailureSitePathResolver.         [reason] printed )
                             resolve + read file ]
                          (real compiler paths are ABSOLUTE
                           — verified against real swift
                           build output — resolved directly,
                           never joined onto repoRoot)
                                          |
                                          v
                          [ FailureSitePathResolver.
                             repoRelativePath ]
                          (the LLM is shown a clean relative
                           path from here on, never the
                           absolute one — git apply rejects
                           an absolute path in a diff header)
                                          |
                                          v
                              [ PatchGenerator.proposePatch ]
                              (Claude, single-file diff only,
                               never applies it — ADR-002)
                                          |
                                          v
                              [ transition: .patchProposed ]
                                          |
                                          v
                              [ RemediationPolicy.
                                 isPatchAllowed ]
                              (≤1 file, forbidden paths:
                               its own source, .github/,
                               Package.swift — case-
                               insensitive)
                                          |
                                  < patch allowed? >---No---> [ transition:
                                          |                     .policyRejected ]
                                         Yes                           |
                                          |                            v
                                          v                   ( fail job, blocked
                              [ UnifiedDiffInspector.          [reason] printed )
                                 matchesClaimedPath ]
                              (does the diff's own +++
                               header — every one, not
                               just the first — actually
                               match file_path? closes the
                               gap between what the policy
                               validated and what git apply
                               would really write)
                                          |
                                  < diff matches claim? >---No---> [ transition:
                                          |                          .policyRejected ]
                                         Yes                                |
                                          |                                 v
                                          v                        ( fail job, blocked
                              [ transition: .validating ]           [reason] printed )
                                          |
                                          v
                          [ SandboxValidator.validate ]
                          (disposable git worktree, real
                           swift build + swift test,
                           killed if it hangs — ADR-004,
                           docs/runbooks/sandbox-hang.md)
                                          |
                                  < sandbox passed? >
                                     |            |
                                    No            Yes
                                     |             |
                                     v             v
                       [ transition:      [ transition: .sandboxPassed ]
                        .sandboxFailed ]              |
                            |                          v
                            v              < IdempotencyStore already has
                   ( fail job, applied=    a create_pr result for this
                    build=/test= printed )  fingerprint? >
                                              |            |
                                             Yes           No
                                              |             |
                                              v             v
                                  ( print existing   [ GitHubPRWriter.
                                    PR URL, done —      createDraftPR ]
                                    no duplicate,      (branch, commit, push,
                                    ADR-006 )           gh pr create --draft
                                                         — never non-draft,
                                                         never merges — ADR-003)
                                                                |
                                                        < gh/git succeeded? >
                                                           |            |
                                                          No           Yes
                                                           |             |
                                                           v             v
                                              [ transition:   [ transition: .prOpened ]
                                               .prFailed ]    [ IdempotencyStore.
                                                   |            recordProcessed ]
                                                   v                    |
                                          ( fail job,                  v
                                           rethrow error )      ( X ) draft PR open,
                                                                  waiting for a human
```

CI's job ends at `( X )`. Every state above the line CI produces is recorded durably — `RemediationStateMachine` persists each `transition:` step to SQLite (ADR-005), so a crashed run resumes from exactly where it left off instead of silently repeating (or skipping) work.

## Flow B: CD — draft PR to verified production fix **(TARGET, not implemented)**

Nothing below this line runs anywhere. This is the design `docs/architecture/PART_B` sections 34-45 lay out in full depth; this is the same flow compressed to one screen, still tagged honestly.

```
              ( X ) draft PR open  (same connector as the end of Flow A)
                        |
                        v
              [ HUMAN reviews and merges ]
              (the one step in this whole document
               this codebase does not, and will not,
               perform itself — ADR-003)
                        |
                        v
              [ CI builds a signed, immutable
                artifact: sha256:... ]
                        |
                        v
              [ manifest repo: image.digest = sha256:... ]
                        |
                        v
              [ Argo CD: Fetch (git pull, its own
                creds) -> Diff (vs live state) -> Sync ]
              (pull-based — this codebase never holds
               standing cluster credentials)
                        |
                        v
              [ Argo Rollouts: canary 5% -> 25% -> 50% -> 100% ]
                        |
              < health stays within per-service
                SLO for several consecutive windows? >
                   |                          |
                  No                         Yes
                   |                          |
                   v                          v
      [ CAS the deployed-version    < at 100% yet? >
        pointer back to last-             |    |
        known-good; Argo CD            No       Yes
        reconciles again — a               |     |
        forward compensating         (advance    v
        transaction, not a           canary)  ( fix verified in
        literal undo ]                          production, fingerprint
                   |                             does not recur during
                   v                             the verification window )
      ( rolled back, PagerDuty/
        Jira updated, remediation
        history records the
        rollback )
```

## Why the two flows are separate diagrams, not one pipe

Same four reasons `docs/architecture/PART_B` section 35 gives, restated at the diagram level:

1. **Different blast radius.** A CI failure (a bad patch, a failing sandbox) is scoped to one draft PR nobody has to look at until they choose to. A CD failure is live in front of whatever's actually deployed — which, today, is nothing, because there's nothing deployed.
2. **Different owner.** CI is this codebase's own responsibility end to end, and it's the only half I can actually demonstrate. CD's owner would be whatever real deployment target eventually exists — it isn't this repo's job to pretend to be that owner in the meantime.
3. **The artifact digest (or, today, the draft PR itself) is the real seam.** Flow A ends at a concrete, inspectable artifact — a draft PR a human can read. Flow B would start from a signed, immutable build of whatever that PR becomes *after* a human merges it, never a rebuild.
4. **Different remediation mechanics.** A CI failure just fails the job — nothing to compensate for. A CD failure triggers a forward compensating transaction (the CAS-and-reconcile rollback above), a completely different mechanism that has no equivalent anywhere in Flow A.

## What this diagram is not

It's not a claim that Flow B exists. Every box in it is unimplemented, unprovisioned, untested — see `docs/architecture/WHAT_I_DID_NOT_BUILD.md` for the full list of exactly what's missing and why each piece was left out on purpose rather than half-built. Flow A is the entire, real system. Flow B is where it would go next, drawn honestly as a plan, not dressed up as a status report.

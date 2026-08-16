# ADR-007: xctriage does not implement continuous deployment, GitOps, or Kubernetes integration

## Context

`docs/architecture/PART_B` (sections 34-114) is a detailed *target-state*
design for a full CI/CD platform: GitOps reconciliation, canary rollouts,
Argo CD/Rollouts, deployment leases, SLO-based gates, multi-region
failover. None of that infrastructure exists in this repository or has
ever been provisioned. What exists is: parse a build log or `.xcresult` →
classify → fingerprint → policy-gate → generate a patch → validate it in a
sandbox → open a draft PR. That's it. There is no Kubernetes cluster, no
Argo CD instance, no Terraform state, no Kafka topic, anywhere near this
codebase.

## Decision

This codebase will not contain fake or stubbed clients for infrastructure
that isn't real — no `KubernetesDeployer` that doesn't talk to a cluster,
no `ArgoCDReconciler` that doesn't reconcile anything, no `CanaryController`
that has never seen production traffic. `docs/architecture/PART_B`
stays clearly labeled as proposed target design (every section that
describes CD/GitOps/K8s explicitly frames it as a design, not a
description of running infrastructure). Every ADR in this directory
documents a decision about code that actually exists and actually runs.

## Alternatives

- **Build stub/mock implementations of the CD layer** (an in-memory fake
  Argo CD, a fake Kubernetes API) so the design docs have working code
  behind them. Rejected: a fake reconciler that never reconciles anything
  real teaches nothing about the actual hard parts of GitOps (drift
  detection against a real API server, real webhook timing, real RBAC
  boundaries) and risks reading, to anyone skimming the repo, as more real
  than it is. That directly conflicts with this project's own accuracy
  standard — see "Never fabricate metrics, deployment claims" in the
  project's engineering guidance.
- **Actually provision the infrastructure** (a real EKS/GKE cluster, real
  Argo CD, real Terraform). Would make the design real, but is a
  significant ongoing cost and operational surface for a project whose
  proven, tested core is a Swift CLI — and it isn't what was asked for in
  any of the actual feature work done so far.

## Why chosen

The honest and useful thing this repository can do with a 114-point
platform-engineering spec it didn't build the platform for is: implement,
test, and ship the pieces that are real (state machine, idempotency,
policy, sandbox, draft PRs — see ADR-002 through ADR-006), and describe
the rest as exactly what it is — a design a Staff/Principal-level review
would produce for where this goes next, not a changelog of what's running.

## Consequences

- Anyone reading `docs/architecture/PART_B` needs the framing in this ADR
  to correctly calibrate what's implemented vs. proposed. That framing
  lives in the doc's own language (target/proposed, not "the system does")
  and is reinforced here.
- Sections of the target design that assume real infrastructure (SLO-gated
  canary promotion, deployment leases with fencing tokens, GitOps drift
  reconciliation) cannot be tested with `swift test` the way the rest of
  this codebase is, because there's nothing running to test against. This
  is expected, not a gap to silently fill with fakes.

## When to revisit

If and when this project actually provisions real deployment
infrastructure (even a single local/dev Kubernetes cluster, per section 111's
recommended MVP vertical slice), move the relevant PART_B sections from
"target design" to "implemented," write real tests against the real
system, and add an ADR for that specific integration the same way
ADR-001 through ADR-006 document what's real today.

# Target design: Actions Runner Controller + Argo CD for xctriage

**This is a target-architecture design-review document, not a description
of what xctriage currently runs** — same framing as `PART_B`, sections
34-42, which this extends. Per **ADR-007** and
[`WHAT_I_DID_NOT_BUILD.md`](WHAT_I_DID_NOT_BUILD.md#kubernetes-argo-cd-gitops-reconciliation),
there is no Kubernetes cluster, no Argo CD instance, and no Actions Runner
Controller install behind this repo today. Every manifest below is
proposed and untested against a live control plane; nothing here has been
`kubectl apply`'d anywhere. Written down because a Staff/Principal review
of "what's next after CI" produces exactly this kind of design — the honest
place for it is a labeled sketch, not files that look like running infra.

## Why this exists as a separate doc from `WHAT_I_DID_NOT_BUILD.md`

That doc records the decision not to build GitOps/K8s yet, and why. This
doc is what "yet" would look like — the concrete shape, not just the
rejection. It doesn't change the verdict: still not built, still needs a
real target cluster first (see ADR-007's "When to revisit").

---

## Part 1: Actions Runner Controller (ARC)

### What ARC actually is, and its hard ceiling

ARC (`actions/actions-runner-controller`) is a Kubernetes controller that
manages ephemeral GitHub Actions runner pods — an `AutoscalingRunnerSet`
custom resource replaces `runs-on: ubuntu-latest` with a self-hosted
runner-scale-set label backed by pods your cluster schedules and destroys
per job.

**ARC cannot run this repo's actual build job.** `ci.yml`'s `test` job
needs `runs-on: macos-15` and `xcode-select --switch` because Swift 6
strict-concurrency builds against Apple frameworks and `xcrun
xcresulttool` both require a real Xcode install — and ARC only schedules
Linux (or Windows-on-Windows-nodes) containers. There is no macOS
container image and no macOS container runtime; Apple's software license
restricts macOS virtualization to Apple hardware, which is exactly why
GitHub's own `macos-*` runners are bare-metal Mac minis, not containers.
**Moving the Swift build/test job onto ARC is not a configuration problem
to solve — it's structurally impossible with this tool.** That job stays
on GitHub-hosted (or self-hosted bare-metal Mac) runners regardless of
anything below.

What ARC *can* legitimately take over, because they're already
Linux-only in `ci.yml` and `claude-pr-review.yml`: `dependency-review`,
`trivy`, and the new Claude PR review job — plus, per Part 2 below, a
target `build-and-push-image` job for this repo's own `Dockerfile`.

### Target manifest — scoped to what ARC can actually run

```yaml
# arc-runner-set.yaml (TARGET — not installed anywhere)
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: xctriage-linux-runners
  namespace: arc-runners
spec:
  githubConfigUrl: https://github.com/gerardrecinto/xctriage
  githubConfigSecret: xctriage-arc-github-token   # GitHub App or PAT, ARC-managed K8s Secret
  minRunners: 0
  maxRunners: 4
  template:
    spec:
      containers:
        - name: runner
          image: ghcr.io/actions/actions-runner:latest
          command: ["/home/runner/run.sh"]
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "2"
              memory: 4Gi
          volumeMounts:
            - name: spm-cache
              mountPath: /home/runner/.swiftpm/cache
      volumes:
        - name: spm-cache
          persistentVolumeClaim:
            claimName: xctriage-spm-cache   # shared across runner pods; speeds up `swift package resolve`
```

No Docker-in-Docker sidecar here on purpose: `dependency-review` and
`trivy` don't build images. The one job that would need it —
`build-and-push-image` (Part 2) — mounts `/var/run/docker.sock` from a
node-level Docker daemon instead of running DinD, which avoids DinD's
usual privileged-container and layer-cache cold-start problems for a
low-frequency (tag-push-only) job.

Then in the workflow: `runs-on: xctriage-linux-runners` in place of
`ubuntu-latest`, or — as already wired in `claude-pr-review.yml` — set the
`LINUX_RUNNER` repo Variable to the runner-scale-set label and every
Linux-only job picks it up with no workflow-file edit.

### Why ARC over GitHub-hosted, if it's this narrow

Self-hosted runners only pay for themselves at a request volume GitHub-hosted
minutes get expensive at, or when a job needs something GitHub-hosted
runners can't give it (a private network peer, a specific CPU
architecture, a persistent cache volume). For three lightweight Linux
jobs on a single-CLI-tool repo, that threshold isn't close to met today —
this section exists as the honest answer to "how would you scale this,"
not a recommendation to provision it now.

---

## Part 2: Argo CD

### What there actually is to deploy

xctriage is a CLI binary (`GitHub Releases`, see `release.yml`), not a
long-running service — there is no pod for Argo CD to keep in sync in the
way it would for a web app. The one deployable shape that's honest for a
CLI tool is a **scheduled Kubernetes `CronJob`** running the `Dockerfile`
image from this repo, invoking a command the CLI already has and is
already tested (`xctriage flaky`), against a `PersistentVolumeClaim`
holding the same SQLite flaky-test database `FlakyTestTracker` already
writes locally. It's the existing `flaky` subcommand and the existing
`SlackReporter`, invoked on a schedule instead of from CI — not a new
service invented to give Argo CD something to sync.

### Target CD flow

```
tag push (v*)
  -> build-and-push-image (Linux, ARC-eligible): docker build . && push ghcr.io/gerardrecinto/xctriage:<tag>
  -> Kustomize overlay bumps the image tag under deploy/flaky-report/
  -> Argo CD: fetch desired state (this repo, deploy/flaky-report/) -> diff against live cluster -> sync
  -> CronJob runs `xctriage flaky --n 20 --output slack` on schedule
```

This is pull-based CD (PART_B section 36's distinction): the CI system
never gets cluster credentials, only pushes to `ghcr.io` and to Git. Argo
CD, running in-cluster, is the only thing with write access to the
cluster.

### Target manifests

```yaml
# argocd-application.yaml (TARGET — no Argo CD instance exists to apply this to)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: xctriage-flaky-report
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/gerardrecinto/xctriage
    targetRevision: main
    path: deploy/flaky-report
    kustomize:
      images:
        - ghcr.io/gerardrecinto/xctriage=ghcr.io/gerardrecinto/xctriage:v1.6.1
  destination:
    server: https://kubernetes.default.svc
    namespace: xctriage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# deploy/flaky-report/cronjob.yaml (TARGET — deploy/ does not exist in this repo)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: xctriage-flaky-report
spec:
  schedule: "0 13 * * MON-FRI"   # 6am Pacific, weekdays
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: xctriage
              image: ghcr.io/gerardrecinto/xctriage:v1.6.1
              args: ["flaky", "--n", "20", "--output", "slack"]
              envFrom:
                - secretRef:
                    name: xctriage-slack-webhook
              volumeMounts:
                - name: flaky-db
                  mountPath: /home/appuser/.xctriage
          restartPolicy: OnFailure
          volumes:
            - name: flaky-db
              persistentVolumeClaim:
                claimName: xctriage-flaky-db
```

### What would justify actually building this

Same test as the parent doc: an actual target cluster to deploy to — even
a single local/dev one — per PART_B section 111's recommended MVP
vertical slice. Until then this stays a sketch, and `ADR-007`'s verdict
("not built") stands.

---

## Verification commands (what these can honestly be checked against today)

`AutoscalingRunnerSet` and Argo CD's `Application` are both CRDs, not
built-in Kubernetes types — a plain `kubectl apply --dry-run=client`
against a stock cluster fails with `no matches for kind`, not because the
YAML is wrong, but because the CRDs aren't installed. What's actually
checkable without a cluster:

```bash
# Syntax/structure only — catches YAML errors, not semantic ones
yamllint arc-runner-set.yaml argocd-application.yaml deploy/flaky-report/cronjob.yaml

# Schema validation against the real CRD schemas (kubeconform's default
# schema registry knows actions.github.com and argoproj.io)
kubeconform -strict -verbose arc-runner-set.yaml argocd-application.yaml

# The one plain-Kubernetes manifest here (no CRD) — this one DOES dry-run cleanly
kubectl apply --dry-run=client -f deploy/flaky-report/cronjob.yaml

# Against a real cluster with the CRDs installed (not run here — no cluster exists):
# helm install arc actions-runner-controller/actions-runner-controller-2 -n arc-systems --create-namespace
# kubectl apply -f arc-runner-set.yaml
# argocd app diff xctriage-flaky-report
```

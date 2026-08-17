# ADR-004: Patch validation happens in a disposable git worktree, not the caller's tree

## Context

Before any patch becomes a PR, it has to be proven to actually build and
fix the target test. `SandboxValidator` (`Sources/XCTriageKit/Remediation/
SandboxValidator.swift`) is the type that proves this.

## Decision

`SandboxValidator.validate` creates a throwaway `git worktree` under
`NSTemporaryDirectory()`, applies the proposed diff there, runs
`swift build` and a targeted `swift test` inside that worktree, and tears
the worktree down whether validation passed or failed. It never touches
`repoRoot` — the caller's actual working tree — directly.

## Alternatives

- **Apply and build in the caller's working tree, then revert.** Fewer
  moving parts, but a build/test failure mid-run (or a crash before the
  revert runs) can leave a developer's or CI's working tree dirty or in a
  half-applied state. A worktree can be deleted unconditionally with no
  effect on the tree it was cloned from.
- **A real container/VM sandbox** (Docker, a Firecracker microVM). Stronger
  isolation — the patch can't do anything the worktree's filesystem
  permissions don't already prevent, but a `swift build` runs arbitrary
  build-script code either way. Rejected for now: this tool runs on
  macOS CI (`xcodebuild`/`swift test` need the host toolchain and,
  eventually, a simulator), so a Linux container doesn't reproduce the
  target environment, and a full VM sandbox is more infrastructure than an
  untrusted single-file diff from a policy-gated, narrow-allowlist source
  currently justifies.

## Why chosen

A git worktree is already how this codebase isolates changes (it's the
same primitive `GitHubPRWriter` implicitly relies on via `git checkout -b`),
it's fast to create and destroy, and "never touches the caller's tree"
is a property that's easy to state and easy to verify by reading the type —
`repoRoot` only appears as an argument to `git worktree add`.

## Consequences

- "Tears the worktree down whether validation passed or failed" was true
  as a design intent from the start, but not true in the first
  implementation: the cleanup was a fire-and-forget `Task { ... }` inside a
  `defer`, never awaited. In a short-lived CLI process, that detached task
  races process exit and loses almost every time, so worktrees leaked on
  essentially every real invocation — reproduced with a regression test
  before fixing it (a deliberately slow fake `git worktree remove` proved
  `validate()` was returning before cleanup finished). Fixed by restructuring
  `validate()` to await cleanup on both the success and thrown-error paths.
  Worth noting here specifically because it's a reminder that "the design
  says X" and "the code does X" are different claims — this ADR was
  originally written describing the intent, not (yet, at the time) a
  verified fact about the implementation.
- Validation isolation is filesystem-level, not process/kernel-level. A
  patch that could somehow break out of the worktree during `swift build`
  (arbitrary code in a build plugin, for instance) isn't contained by this
  design. `RemediationPolicy`'s forbidden-path list is the actual defense
  against that class of risk today, not the worktree.
- Validation needs the real toolchain (`/usr/bin/git`, `/usr/bin/swift`)
  present on whatever machine runs it. There's no fallback path if they're
  missing — `validate` just fails.

## When to revisit

If xctriage ever needs to validate patches for untrusted or
externally-submitted failure reports (as opposed to the project's own CI
failures), move to real process/kernel isolation before that day, not
after. The current design assumes the input (a `.xcresult` bundle or build
log from this project's own CI) is not adversarial.

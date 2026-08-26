#!/usr/bin/env python3
"""Claude-based PR quality review: technical-debt score, violation list,
optional GitHub suggestion blocks. Posts (or updates) one PR comment.

Separate from xctriage's own CI-failure triage (RuleClassifier /
ClaudeClassifier, wired into ci.yml and the Jenkinsfile): that pipeline
explains why a build/test *failed*. This script runs on every PR whether
or not anything failed, and reviews the diff itself for complexity,
concurrency-safety, and maintainability risk before it merges.

Deliberately does not generate a `remediate/pr-<id>-fixes` branch. xctriage
already has a tested, policy-gated, sandbox-validated patch pipeline
(RemediationPolicy -> PatchGenerator -> SandboxValidator -> GitHubPRWriter,
see docs/adr/ADR-002 through ADR-006) — a second, ad hoc branch-pushing
script here would duplicate it with none of those safety gates. High-
confidence findings get a GitHub suggestion block a human can apply with
one click instead.

The "Risk CI" in the review comment is Claude's own self-reported
uncertainty band around its debt score, not a statistically fitted
confidence interval — there is no historical defect-rate corpus for this
repo to fit one against. Labeled as such everywhere it's shown, in
keeping with this project's own accuracy standard (see
docs/architecture/WHAT_I_DID_NOT_BUILD.md and ADR-007).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Literal

from anthropic import Anthropic
from pydantic import BaseModel, Field

MODEL = "claude-opus-5"  # swap to "claude-sonnet-5" here if per-PR cost matters more than review depth
COMMENT_MARKER = "<!-- xctriage-claude-pr-review -->"

SYSTEM_PROMPT = """You are a senior Swift reviewer scoring a single pull request diff for \
a CI failure-triage CLI tool (xctriage: Swift 6, strict concurrency, actors, SQLite, URLSession).

Score the diff, not the whole repository. Only flag what the diff itself introduces or touches.

technical_debt_score (0-100, 100 = worst): weigh cyclomatic complexity, missing test coverage \
for new logic, and drift from the patterns already established in this codebase (actor \
isolation for shared mutable state, Sendable conformance, no force-unwraps on external input).

confidence (0-100): your own confidence in this score, not a property of the code.

self_reported_risk_low / self_reported_risk_high (0-100): your own uncertainty band around \
technical_debt_score. This is a self-assessment, not a computed statistic — do not imply more \
precision than "how sure am I."

violations: concrete issues only, each anchored to a real file/line from the diff. For \
Swift 6 strict concurrency issues (data races, missing Sendable, actor boundary violations), \
say so explicitly in the category field.

Say nothing about parts of the codebase the diff doesn't touch."""


class Violation(BaseModel):
    file: str
    line: int
    category: Literal[
        "complexity", "concurrency-safety", "test-coverage", "performance",
        "code-smell", "architecture-drift", "other",
    ]
    severity: Literal["low", "medium", "high"]
    message: str
    suggested_replacement: str | None = Field(
        default=None,
        description="Exact replacement text for this line if a one-line fix applies; null otherwise.",
    )


class PRReview(BaseModel):
    technical_debt_score: int = Field(ge=0, le=100)
    confidence: int = Field(ge=0, le=100)
    self_reported_risk_low: int = Field(ge=0, le=100)
    self_reported_risk_high: int = Field(ge=0, le=100)
    summary: str
    violations: list[Violation]


def run_review(diff_text: str) -> PRReview:
    client = Anthropic()
    response = client.messages.parse(
        model=MODEL,
        max_tokens=8000,
        system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": f"Review this PR diff:\n\n```diff\n{diff_text}\n```"}],
        output_format=PRReview,
    )
    return response.parsed_output


def render_comment(review: PRReview, pr_number: int, commit_sha: str) -> str:
    lines = [COMMENT_MARKER]
    lines.append(f"## xctriage Claude PR review — PR #{pr_number} @ `{commit_sha[:8]}`")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append(f"| Technical debt score | {review.technical_debt_score}/100 |")
    lines.append(
        f"| Self-reported risk band* | [{review.self_reported_risk_low}, "
        f"{review.self_reported_risk_high}] |"
    )
    lines.append(f"| Confidence | {review.confidence}% |")
    lines.append("")
    lines.append(
        "\\* Claude's own uncertainty band around the score above — not a statistically "
        "fitted confidence interval. This repo has no historical defect-rate corpus to fit "
        "one against."
    )
    lines.append("")
    lines.append(review.summary)

    if review.violations:
        lines.append("")
        lines.append("<details>")
        lines.append(f"<summary>{len(review.violations)} finding(s) — click to expand</summary>")
        lines.append("")
        for v in review.violations:
            lines.append(f"**{v.file}:{v.line}** — `{v.category}` / `{v.severity}`")
            lines.append(f"{v.message}")
            if v.suggested_replacement is not None and review.confidence >= 90:
                lines.append("```suggestion")
                lines.append(v.suggested_replacement)
                lines.append("```")
            lines.append("")
        lines.append("</details>")

    return "\n".join(lines)


def post_or_update_comment(repo: str, pr_number: int, body: str) -> None:
    existing = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{pr_number}/comments", "--paginate",
         "--jq", f'.[] | select(.body | startswith("{COMMENT_MARKER}")) | .id'],
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    if existing:
        comment_id = existing.splitlines()[0]
        subprocess.run(
            ["gh", "api", f"repos/{repo}/issues/comments/{comment_id}",
             "-X", "PATCH", "-f", f"body={body}"],
            check=True,
        )
    else:
        subprocess.run(
            ["gh", "api", f"repos/{repo}/issues/{pr_number}/comments",
             "-X", "POST", "-f", f"body={body}"],
            check=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff-file", required=True)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--commit-sha", required=True)
    parser.add_argument("--output", default="pr_review.md")
    parser.add_argument("--post", action="store_true", help="post/update the PR comment via gh")
    args = parser.parse_args()

    with open(args.diff_file, encoding="utf-8") as f:
        diff_text = f.read()

    if not diff_text.strip():
        print("Empty diff — nothing to review.")
        return 0

    review = run_review(diff_text)
    comment = render_comment(review, args.pr_number, args.commit_sha)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(comment)
    print(json.dumps(review.model_dump(), indent=2))

    if args.post:
        post_or_update_comment(args.repo, args.pr_number, comment)

    return 0


if __name__ == "__main__":
    sys.exit(main())

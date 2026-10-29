# Security Policy

## Reporting a vulnerability

Email gerardrecinto@gmail.com with the details. Please do not open a public issue for a security problem.

Include what you found, how to reproduce it, and the version or commit. I will reply within a few days and tell you what I plan to do.

## Scope

xctriage is a command line tool. Issues I care about most:

- Secrets or personal data reaching the Claude API when redaction is on.
- A patch proposed by `xctriage remediate` getting past the policy or sandbox checks.
- Anything in the GitHub workflows that exposes a secret or a write token.

## Supported versions

Only the latest release and `main` get fixes.

# Security policy

## Report privately

Email [gerardrecinto@gmail.com](mailto:gerardrecinto@gmail.com?subject=xctriage%20security%20report) with:

- The affected version or commit and source paths.
- A minimal, redacted reproduction and the impact you observed.
- Any relevant configuration, with credentials and private data removed.

Keep credentials, private build logs, and vulnerability details out of public issues. A sanitized fixture is enough to start a report.

## Scope

Reports can cover:

- Build-log parsing and local failure data.
- Unexpected log or credential exposure through the Claude API or Slack output.
- Remediation policy or sandbox bypasses.
- Repository workflows and release artifacts that expose credentials or write access.

## Supported versions

Security fixes target `main` and the latest release. Older versions may require an upgrade. Include the output of `xctriage --version` or the affected commit in your report.

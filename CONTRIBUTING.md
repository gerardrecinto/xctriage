# Contributing

Issues and pull requests are welcome.

## Set up

You need macOS 14 or later with Swift 6.

```bash
git clone https://github.com/gerardrecinto/xctriage.git
cd xctriage
swift build
swift test
```

The first build takes a few minutes.

## Pull requests

- Branch from `main` and keep the change small and focused.
- Add or update tests for behavior you change. `swift test` must pass.
- Run `swiftlint lint --quiet` if you have SwiftLint installed.
- Say what changed and how you tested it in the PR description.
- Do not commit real logs that contain secrets. Use the fixtures in `Tests/XCTriageKitTests/Fixtures/`.

Security problems: see [SECURITY.md](SECURITY.md) instead of opening an issue.

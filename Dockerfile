# Builds the Linux-portable subset of xctriage: build-log/CI-log analysis,
# rule + Claude classification, flaky tracking, remediation proposals,
# SARIF/JSON/Slack/GitHub-annotation output. `.xcresult` bundle parsing
# (XCResultParser) shells out to `xcrun xcresulttool`, which only exists
# inside an Xcode install — there is no Linux xcresulttool, so that one
# code path falls back to "unavailable" at runtime here by design (see
# XCResultParser.swift's own doc comment), exactly like a real macOS CI
# agent without Xcode installed. Nothing in this image can produce Xcode
# builds or run XCTest bundles — this is a log-triage image, not a build
# agent. Empirically built and tested against swift:6.0-noble (Docker,
# 2026-08-26) before being written down here; not assumed from Package.swift.
#
# Portability fixes this Dockerfile depends on (all in Sources/, not here):
# CryptoKit -> swift-crypto's `Crypto` on Linux (FailureFingerprint.swift),
# the implicit Darwin `SQLite3` module -> a local CSQLite3 system-library
# target (FlakyTestTracker/IdempotencyStore/RemediationStateMachine), and
# Foundation's URLSession/URLRequest -> FoundationNetworking on Linux
# (ClaudeClassifier/PatchGenerator/SlackReporter).

# ---- Builder ----
FROM swift:6.0-noble AS builder

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        libsqlite3-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Resolve dependencies before copying sources so a source-only change
# doesn't invalidate this layer's cache.
COPY Package.swift Package.resolved ./
COPY Sources/CSQLite3 ./Sources/CSQLite3
RUN swift package resolve

COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build -c release --static-swift-stdlib

# ---- Runtime ----
FROM ubuntu:noble AS runtime

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        ca-certificates \
        libcurl4 \
        libsqlite3-0 \
        libssl3 \
        git \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 appuser \
    && useradd --uid 10001 --gid appuser --create-home --shell /usr/sbin/nologin appuser

COPY --from=builder /build/.build/release/xctriage /usr/local/bin/xctriage
RUN chmod 755 /usr/local/bin/xctriage

USER appuser
WORKDIR /home/appuser

ENTRYPOINT ["/usr/local/bin/xctriage"]
CMD ["--help"]

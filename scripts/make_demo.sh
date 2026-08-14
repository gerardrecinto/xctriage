#!/usr/bin/env bash
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
BIN=".build/release/xctriage"

echo ""
echo "xctriage demo"
echo ""
sleep 0.4

echo "\$ xctriage analyze Tests/XCTriageKitTests/Fixtures/xcodebuild_compile_failure.log --source xcodebuild --build-id ios27-arm64-5512"
sleep 0.3
$BIN analyze Tests/XCTriageKitTests/Fixtures/xcodebuild_compile_failure.log \
    --source xcodebuild --build-id ios27-arm64-5512
sleep 1.0

echo "\$ xctriage analyze Tests/XCTriageKitTests/Fixtures/xcodebuild_test_failure.log --source xcodebuild --build-id ios27-xctest-8834"
sleep 0.3
$BIN analyze Tests/XCTriageKitTests/Fixtures/xcodebuild_test_failure.log \
    --source xcodebuild --build-id ios27-xctest-8834
sleep 1.2

echo "\$ xctriage analyze Tests/XCTriageKitTests/Fixtures/xcodebuild_compile_failure.log --source xcodebuild --output json | python3 -m json.tool | head -20"
sleep 0.3
$BIN analyze Tests/XCTriageKitTests/Fixtures/xcodebuild_compile_failure.log \
    --source xcodebuild --output json | python3 -m json.tool | head -20
sleep 1.5

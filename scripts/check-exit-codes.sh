#!/usr/bin/env bash
set -euo pipefail

binary="${1:-.build/release/xctriage}"
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

printf '%s\n' 'error: Swift package resolution failed' > "$fixture_dir/dependency.log"
printf '%s\n' '** BUILD SUCCEEDED **' > "$fixture_dir/success.log"

status=0
"$binary" analyze "$fixture_dir/dependency.log" --output json --no-track --exit-code > "$fixture_dir/failure.json" || status=$?
if [ "$status" -ne 1 ]; then
  echo "classified dependency failure should exit 1, got $status" >&2
  cat "$fixture_dir/failure.json" >&2
  exit 1
fi
python3 - "$fixture_dir/failure.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report['classification']['category'] == 'dependency_failure'
assert report['classification']['failure_sites'] == []
PY

"$binary" analyze "$fixture_dir/dependency.log" --output json --no-track > "$fixture_dir/report-only.json"
"$binary" analyze "$fixture_dir/success.log" --output json --no-track --exit-code > "$fixture_dir/success.json"
"$binary" analyze - --output json --no-track --exit-code < "$fixture_dir/dependency.log" > "$fixture_dir/stdin.json" && status=0 || status=$?
if [ "$status" -ne 1 ]; then
  echo "classified dependency failure on stdin should exit 1, got $status" >&2
  exit 1
fi
for message in 'error: unrecognized build failure' '** BUILD FAILED **'; do
  printf '%s\n' "$message" > "$fixture_dir/unclassified.log"
  status=0
  "$binary" analyze "$fixture_dir/unclassified.log" --output json --no-track --exit-code > "$fixture_dir/unclassified.json" || status=$?
  if [ "$status" -ne 1 ]; then
    echo "explicit failure without a known category should exit 1, got $status" >&2
    exit 1
  fi
done
printf '%s\n' 'CLI exit-code checks passed: classified failure, explicit errors, failed marker, report-only mode, clean log, stdin.'

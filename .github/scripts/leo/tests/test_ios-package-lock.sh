#!/usr/bin/env bash
# The iOS workflows skip SwiftPM plugin/macro validation (no one can answer the
# trust prompt in CI), so the app's package graph must be locked: every
# xcodebuild that resolves packages passes -onlyUsePackageVersionsFromResolvedFile,
# against a committed Package.resolved that xcodegen leaves in place.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
pass=0; fail=0
result() { if [[ "$1" == yes ]]; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $2"; fail=$((fail+1)); fi; }
resolved=ios/Leo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git ls-files --error-unmatch "$resolved" >/dev/null 2>&1 && result yes "app Package.resolved is committed" || result no "app Package.resolved is committed"
for wf in leo-ios leo-ios-testflight; do
  f=.github/workflows/$wf.yml
  # every xcodebuild invocation that skips validation must also pin to the resolved file
  skip=$(grep -c -- '-skipPackagePluginValidation' "$f" || true)
  pin=$(grep -c -- '-onlyUsePackageVersionsFromResolvedFile' "$f" || true)
  [[ "$skip" -ge 1 && "$pin" -ge "$skip" ]] && result yes "$wf pins versions wherever it skips validation" || result no "$wf pins versions wherever it skips validation (skip=$skip pin=$pin)"
done
echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

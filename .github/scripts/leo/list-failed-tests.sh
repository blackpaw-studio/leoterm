#!/usr/bin/env bash
# Lists the tests a full Swift Testing run reported as failed, one fully
# qualified `-only-testing` identifier per line (`GhosttyTests/Suite/test()`,
# nested suites included): usage list-failed-tests.sh LOG ENUMERATION_JSON
#
# ENUMERATION_JSON is `xcodebuild test-without-building -enumerate-tests
# -test-enumeration-style flat -test-enumeration-format json` output: every
# test's real identifier, so a nested suite, a suite declared in an extension,
# and a parameterized test (`foo(_:step:)`) resolve exactly as xcodebuild will
# match them, with no reading of the Swift sources.
#
# The log names a failing test (`✘ Test name() failed after ...`, or `✘ Test
# name(_:) with 4 test cases failed after ...` for a parameterized one) and, on
# other lines, the failing suites (`✘ Suite Name failed after ...`), but never
# which suite a test belongs to. A test resolves to the identifier whose last
# two components are a failing suite and the test's name. One that resolves to
# none, or to more than one (the same name in two failing suites), prints as
# `?/name()`: the caller can't rerun it by name, and a guess could pass a rerun
# that never ran the test that failed.
set -euo pipefail

log="${1:?usage: list-failed-tests.sh LOG ENUMERATION_JSON}"
enumeration="${2:?usage: list-failed-tests.sh LOG ENUMERATION_JSON}"

python3 -I - "$log" "$enumeration" <<'PY'
import json
import re
import sys

log_path, enumeration_path = sys.argv[1:3]
TEST = re.compile(r"^✘ Test (.+?)(?: with \d+ test cases?)? failed after ")
SUITE = re.compile(r"^✘ Suite (.+?) failed after ")

tests, suites = [], set()
with open(log_path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        m = SUITE.match(line)
        if m:
            suites.add(m.group(1))
            continue
        m = TEST.match(line)
        # `✘ Test run with N tests ...` is the run's own summary, not a test.
        if m and not m.group(1).startswith("run with ") and m.group(1) not in tests:
            tests.append(m.group(1))

with open(enumeration_path, encoding="utf-8") as f:
    enumerated = json.load(f)
identifiers = [
    t["identifier"]
    for value in enumerated.get("values", [])
    for t in value.get("enabledTests", [])
]

for name in sorted(tests):
    matches = []
    for ident in identifiers:
        parts = ident.split("/")
        if len(parts) >= 3 and parts[-1] == name and parts[-2] in suites:
            matches.append(ident)
    print(matches[0] if len(matches) == 1 else f"?/{name}")
PY

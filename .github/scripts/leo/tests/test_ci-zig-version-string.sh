#!/usr/bin/env bash
# Guards that leo-ci.yml never runs a bare `zig build` (B-317).
# Since B-227 leo-release.yml calls leo-ci.yml on a leo-vX.Y.Z tag, so the
# checkout is a tagged commit. src/build/Config.zig then sees the git tag,
# fails to match it against build.zig, and panics ("tagged releases must be
# in vX.Y.Z format matching build.zig") unless -Dversion-string is passed.
# Pushes to main (untagged HEAD) never hit this. Checks, parsed as YAML:
#   1. every `zig build` command in a leo-ci.yml step passes -Dversion-string.
#   2. that value is derived from build.zig.zon's .version and is guarded
#      against being empty, so it can't drift or silently vanish.
# Run directly:
#   ./test_ci-zig-version-string.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly ci=../../../workflows/leo-ci.yml
readonly ruby=/usr/bin/ruby
pass=0
fail=0

result() {
  local ok="$1" desc="$2" detail="${3:-}"
  if [[ "$ok" == yes ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc${detail:+ ($detail)}"
    fail=$((fail + 1))
  fi
}

if [[ ! -x "$ruby" ]]; then
  result no "YAML parser available" "$ruby not found"
  echo "-- $pass passed, $fail failed --"
  exit 1
fi

# check <desc> <ruby snippet over steps>; the snippet prints a problem, or
# nothing when the check holds. `steps` is every step's run script with
# backslash line continuations joined.
check() {
  local desc="$1" snippet="$2" problem
  problem="$("$ruby" -ryaml -e '
    wf = YAML.safe_load(File.read(ARGV[0])) || {}
    steps = (wf["jobs"] || {}).values.flat_map { |j| j["steps"] || [] }
    scripts = steps.map { |s| s["run"].to_s.gsub(/\\\n\s*/, " ") }
    '"$snippet"'
  ' "$ci" 2>&1)" || problem="parse error: $problem"
  [[ -z "$problem" ]] && result yes "$desc" || result no "$desc" "$problem"
}

check "every zig build in leo-ci.yml passes -Dversion-string" '
  builds = scripts.flat_map { |r| r.lines.select { |l| l =~ /\bzig build\b/ } }
  puts "no zig build found" if builds.empty?
  builds.each { |l| puts "missing -Dversion-string: #{l.strip}" unless l.include?("-Dversion-string") }
'

check "the version string comes from build.zig.zon and is checked non-empty" '
  zig = scripts.select { |r| r =~ /\bzig build\b/ }
  zig.each do |r|
    puts "does not read build.zig.zon" unless r.include?("build.zig.zon")
    puts "no empty-value guard" unless r =~ /\[\[ -z |\[ -z |exit 1/
  end
'

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

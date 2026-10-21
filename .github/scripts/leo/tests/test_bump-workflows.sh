#!/usr/bin/env bash
# Structural guards for the leo bump workflows (leo-bump.yml, which opens the
# pin-bump PR, and leo-bump-release.yml, which tags a merged bump). Parsed as
# YAML, so a refactor can't quietly drop a safety property. Run directly:
#   ./test_bump-workflows.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly bump=../../../workflows/leo-bump.yml
readonly tagger=../../../workflows/leo-bump-release.yml
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

# check DESC FILE RUBY_BODY: RUBY_BODY sees `wf` (parsed workflow) and prints a
# problem per line; no output means the property holds. `on` parses as `true`
# in YAML 1.1, hence `triggers`.
check() {
  local desc="$1" file="$2" body="$3" problems
  if [[ ! -f "$file" ]]; then
    result no "$desc" "missing $file"
    return
  fi
  problems="$("$ruby" -ryaml -e '
    wf = YAML.safe_load(File.read(ARGV[0])) || {}
    triggers = wf["on"] || wf[true] || {}
    jobs = wf["jobs"] || {}
    steps = jobs.values.flat_map { |j| j["steps"] || [] }
    '"$body"'
  ' "$file" 2>&1)" || problems="ruby failed: $problems"
  [[ -z "$problems" ]] && result yes "$desc" || result no "$desc" "$problems"
}

# -- both workflows -----------------------------------------------------------

for wf_file in "$bump" "$tagger"; do
  name="$(basename "$wf_file")"

  check "$name: every third-party action is pinned to a full commit sha" "$wf_file" '
    jobs.each do |id, j|
      ([j["uses"]] + (j["steps"] || []).map { |s| s["uses"] }).compact.each do |u|
        next if u.start_with?("./")
        puts "#{id}: #{u}" unless u =~ /\A[^@]+@[0-9a-f]{40}\z/
      end
    end'

  check "$name: no expression is interpolated into a run: script" "$wf_file" '
    steps.each do |s|
      puts "step #{s["name"]}: #{s["run"].lines.grep(/\$\{\{/).first.strip}" if s["run"].to_s.include?("${{")
    end'

  check "$name: sets least-privilege permissions (contents read, nothing writable)" "$wf_file" '
    perms = [wf["permissions"]] + jobs.values.map { |j| j["permissions"] }
    puts "no top-level permissions" unless wf["permissions"].is_a?(Hash)
    perms.compact.each do |p|
      puts "writable: #{p.inspect}" if p.values.any? { |v| v == "write" }
    end'

  check "$name: serialises runs without cancelling one mid-push" "$wf_file" '
    c = wf["concurrency"]
    puts "no concurrency group" unless c.is_a?(Hash) && c["group"].to_s != ""
    puts "cancel-in-progress must be false" if c.is_a?(Hash) && c["cancel-in-progress"] != false'

  check "$name: pushes with LEO_BUMP_TOKEN, not GITHUB_TOKEN" "$wf_file" '
    text = File.read(ARGV[0])
    puts "LEO_BUMP_TOKEN not used" unless text.include?("secrets.LEO_BUMP_TOKEN")'
done

# -- leo-bump.yml -------------------------------------------------------------

check "leo-bump.yml: fires on repository_dispatch leo-release and workflow_dispatch" "$bump" '
  rd = triggers["repository_dispatch"]
  puts "repository_dispatch types: #{rd.inspect}" unless rd.is_a?(Hash) && rd["types"] == ["leo-release"]
  wd = triggers["workflow_dispatch"]
  inputs = wd.is_a?(Hash) ? (wd["inputs"] || {}).keys.sort : []
  puts "workflow_dispatch inputs: #{inputs.inspect}" unless inputs == %w[sha256 version]'

check "leo-bump.yml: payload and inputs reach scripts through env, validated by bump-leo.sh" "$bump" '
  text = File.read(ARGV[0])
  puts "no client_payload.version" unless text.include?("github.event.client_payload.version")
  puts "no client_payload.sha256" unless text.include?("github.event.client_payload.sha256")
  runs = steps.map { |s| s["run"].to_s }.join("\n")
  puts "bump-leo.sh not run" unless runs.include?("bump-leo.sh")
  puts "fetch-leo.sh not run" unless runs.include?("fetch-leo.sh")'

check "leo-bump.yml: bump branch is bump/leo-<version> and the PR targets main" "$bump" '
  runs = steps.map { |s| s["run"].to_s }.join("\n")
  puts "no bump/leo- branch" unless runs.include?("bump/leo-")
  puts "no --base main" unless runs =~ /--base\s+main/'

# -- leo-bump-release.yml -----------------------------------------------------

check "leo-bump-release.yml: runs only for a merged same-repo bump/leo-* PR into main" "$tagger" '
  pr = triggers["pull_request"]
  puts "trigger: #{pr.inspect}" unless pr.is_a?(Hash) && pr["types"] == ["closed"] && pr["branches"] == ["main"]
  conds = jobs.values.map { |j| j["if"].to_s }
  puts "no merged guard" unless conds.all? { |c| c.include?("github.event.pull_request.merged == true") }
  puts "no bump/leo- guard" unless conds.all? { |c| c.include?("bump/leo-") }
  puts "no same-repo guard" unless conds.all? { |c| c.include?("github.event.pull_request.head.repo.full_name == github.repository") }'

check "leo-bump-release.yml: tags the merge commit via next-leo-tag.sh" "$tagger" '
  runs = steps.map { |s| s["run"].to_s }.join("\n")
  puts "next-leo-tag.sh not run" unless runs.include?("next-leo-tag.sh")
  puts "no git push of the tag" unless runs =~ /git push\b.*\bTAG\b|git push\b.*refs\/tags/'

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

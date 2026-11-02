#!/usr/bin/env bash
# A leo-release.yml workflow_dispatch is a dry run: it must never create a
# GitHub release (published appcast.xml feeds Sparkle auto-update, which is
# irreversible once users install). Checks, parsed as YAML:
#   1. leo-release.yml has a workflow_dispatch trigger.
#   2. the "Publish release" step only runs on a tag push.
#   3. the dry-run path (dispatch) uploads the appcast as an artifact.
#   4. gh release create appears only in steps gated on a tag push.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
readonly release=../../../workflows/leo-release.yml
readonly ruby=/usr/bin/ruby
pass=0; fail=0
result() { if [[ "$1" == yes ]]; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $2${3:+ ($3)}"; fail=$((fail+1)); fi; }
check() {
  local desc="$1" snippet="$2" problem
  problem="$("$ruby" -ryaml -e '
    wf = YAML.safe_load(File.read(ARGV[0])) || {}
    triggers = wf["on"] || wf[true] || {}
    steps = (wf["jobs"] || {}).values.flat_map { |j| j["steps"] || [] }
    '"$snippet"'
  ' "$release" 2>&1)" || problem="parse error: $problem"
  [[ -z "$problem" ]] && result yes "$desc" || result no "$desc" "$problem"
}
check "leo-release.yml has a workflow_dispatch dry run" '
  puts "no workflow_dispatch" unless triggers.is_a?(Hash) && triggers.key?("workflow_dispatch")
'
check "Publish release only runs on a tag push" '
  s = steps.find { |x| x["name"] == "Publish release" }
  puts "no Publish release step" unless s
  puts "ungated: #{s["if"].inspect}" if s && s["if"].to_s.strip != "github.event_name == '"'"'push'"'"'"
'
check "every step that runs gh release create is gated on a push" '
  steps.select { |x| x["run"].to_s.include?("gh release create") }.each do |x|
    puts "#{x["name"]} not gated" unless x["if"].to_s.include?("github.event_name == '"'"'push'"'"'")
  end
'
check "dispatch path uploads the appcast as an artifact" '
  s = steps.find { |x| x["uses"].to_s.start_with?("actions/upload-artifact") && x["with"].to_s.include?("appcast.xml") }
  puts "no appcast upload step" unless s
  puts "appcast upload would not run on dispatch" if s && !s["if"].to_s.include?("workflow_dispatch")
'
echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]

#!/bin/bash
# Generate the LaunchAgent plist Leo.app registers through
# SMAppService.agent(plistName:) to run its bundled leo daemon. Run by the
# "Leo LaunchAgent plist" build phase from the LEO_DAEMON_LABEL setting.
# Usage: leo-launch-agent-plist.sh LABEL BUNDLE_ID OUT
#
# The plist is static and signed with the app, so it holds nothing per-user:
# no ~, no --config, no log paths (the daemon writes ~/.leo/state/service.log
# itself) and no WorkingDirectory. The daemon's real environment comes from
# managed.json's env; PATH here only covers the moment before it applies.
# ProcessType and ThrottleInterval are left to launchd's defaults.
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: leo-launch-agent-plist.sh LABEL BUNDLE_ID OUT" >&2; exit 2; }
label="$1" bundle_id="$2" out="$3"

# Reverse-DNS only, which also keeps both values safe to splice into XML.
readonly reverse_dns='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
[[ "$label" =~ $reverse_dns ]] || { echo "error: invalid launchd label '$label'" >&2; exit 1; }
[[ "$bundle_id" =~ $reverse_dns ]] || { echo "error: invalid bundle id '$bundle_id'" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>BundleProgram</key>
	<string>Contents/Helpers/leo</string>
	<key>ProgramArguments</key>
	<array>
		<string>leo</string>
		<string>service</string>
		<string>--supervised</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$bundle_id</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
EOF
plutil -lint -s "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$out"

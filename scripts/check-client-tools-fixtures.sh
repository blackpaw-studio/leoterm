#!/usr/bin/env bash
# Fails if the client-tools wire fixtures differ between leoterm and the leo daemon repo.
# Usage: check-client-tools-fixtures.sh [path-to-leo-repo]   (default ~/.leo/agents/leo)
set -euo pipefail
leo_repo="${1:-$HOME/.leo/agents/leo}"
here="$(cd "$(dirname "$0")/.." && pwd)"
a="$leo_repo/internal/clienttools/testdata/wire"
b="$here/Packages/LeoKit/Tests/LeoKitTests/Fixtures/client-tools"
for d in "$a" "$b"; do [ -d "$d" ] || { echo "missing fixture dir: $d" >&2; exit 2; }; done
diff -r "$a" "$b" || { echo "client-tools fixtures drifted between leo and leoterm" >&2; exit 1; }

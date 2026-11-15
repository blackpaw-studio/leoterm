#!/bin/bash
# Compile the tmux-256color entry Leo.app ships for its bundled tmux into a
# terminfo directory (the bundle's Contents/Resources/terminfo, beside
# Ghostty's own entries). Run by the "Leo tmux terminfo" build phase.
# Usage: leo-terminfo.sh SOURCE OUT_DIR
#
# Always macOS's /usr/bin/tic: a newer tic (Homebrew ncurses >= 6.1) writes
# the extended-number format that the system libncurses tmux links cannot
# read. The daemon points TERMINFO_DIRS at OUT_DIR.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: leo-terminfo.sh SOURCE OUT_DIR" >&2; exit 2; }
src="$1" out="$2"
[[ -f "$src" ]] || { echo "error: leo-terminfo: no such source $src" >&2; exit 1; }

mkdir -p "$out"
/usr/bin/tic -x -o "$out" "$src"
[[ -f "$out/74/tmux-256color" ]] || {
  echo "error: leo-terminfo: tic did not produce $out/74/tmux-256color" >&2
  exit 1
}

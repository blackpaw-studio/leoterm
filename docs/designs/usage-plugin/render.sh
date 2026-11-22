#!/bin/sh
# Renders every mockup in src/ to PNG at 2x, light and dark, with headless Chrome.
# Usage: ./render.sh   (from any directory)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render() { # page width height
  for theme in light dark; do
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
      --window-size="$2,$3" --screenshot="$here/$1-$theme.png" \
      "file://$here/src/$1.html#$theme" >/dev/null 2>&1
  done
}
render sidebar 520 760
render palette 700 850
render meter 980 1130

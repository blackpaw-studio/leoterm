#!/bin/bash
# Writes one deterministic file per B-278 preview kind into <dir>, for
# screenshots of the editor pane's previews: png, gif (animated), heic,
# webp, svg, mp4, Markdown (table + code block), pdf and zip.
# Usage: macos/scripts/leo-preview-fixtures.sh <dir>   (needs ffmpeg, cwebp, sips, zip)
set -euo pipefail

dir="${1:?usage: leo-preview-fixtures.sh <dir>}"
mkdir -p "$dir"
cd "$dir"

ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x400:rate=1" -frames:v 1 shot.png
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=240x160:rate=10" -t 2 -loop 0 spinner.gif
cwebp -quiet shot.png -o photo.webp
sips -s format heic shot.png --out photo.heic > /dev/null
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x360:rate=30" -t 4 -pix_fmt yuv420p clip.mp4
sips -s format pdf shot.png --out doc.pdf > /dev/null

cat > logo.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <rect width="320" height="200" rx="24" fill="#2b5fd9"/>
  <circle cx="100" cy="100" r="52" fill="#ffd34d"/>
  <text x="170" y="114" font-family="Helvetica" font-size="40" fill="#fff">Leo</text>
</svg>
SVG

cat > README.md <<'MD'
# Preview fixtures

Rendered **Markdown** with *emphasis*, `inline code` and a [link](https://example.com).

> A quote, drawn with a bar beside it.

1. First
2. Second
   - Nested

| Kind  | Opens as        |
|-------|-----------------|
| png   | image           |
| mp4   | movie           |
| pdf   | Quick Look      |

```swift
let preview = LeoFilePreviewKind(path: "shot.png")
print(preview)
```
MD

printf 'PK\003\004 not really a zip, binary \000\001\002' > archive.bin
rm -f archive.zip && zip -q -X archive.zip README.md logo.svg
echo "wrote fixtures to $dir"

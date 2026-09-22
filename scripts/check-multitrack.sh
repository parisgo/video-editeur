#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/video-editeur-multitrack.XXXXXX)"
for entry in 'a red' 'b blue'; do
  read -r name color <<< "$entry"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=$color:s=320x180:r=30:d=2" -f lavfi -i "sine=frequency=440:duration=2" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$CHECK_DIR/$name.mp4"
done
for language in zh en; do
  dist/VideoEditeur.app/Contents/MacOS/VideoEditeur --smoke-multitrack "$CHECK_DIR" -editor.interfaceLanguage "$language"
done
printf 'Artifacts: %s\n' "$CHECK_DIR"

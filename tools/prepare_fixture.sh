#!/usr/bin/env bash
# Builds the test fixtures from the public-domain source clip:
#   "Video Blog- CBP Super Bowl LII Countdown to Kickoff - Day 1"
#   U.S. Customs and Border Protection, public domain (work of the U.S. federal government)
#   https://commons.wikimedia.org/wiki/File:Video_Blog-_CBP_Super_Bowl_LII_Countdown_to_Kickoff_-_Day_1.webm
# Usage: tools/prepare_fixture.sh /path/to/downloaded.webm
set -euo pipefail
SRC=${1:?path to the downloaded .webm}
OUT="$(cd "$(dirname "$0")/.." && pwd)/Tests/Fixtures"
LOCAL="$OUT/local"
mkdir -p "$OUT" "$LOCAL"

# 10 s, 1280x720, H.264 + AAC: committed fixture for unit and end-to-end tests.
ffmpeg -loglevel error -y -ss 39.5 -t 10 -i "$SRC" \
  -vf scale=1280:720 -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 128k -movflags +faststart "$OUT/clip.mp4"

# 2 s, stored sideways (360x640, rotated 90° counter-clockwise) and tagged to
# display rotated 90° clockwise, like phone footage: upright 640x360 on playback.
# Encode first, then tag in a stream-copy remux (re-encoding would bake the rotation in).
TMP=$(mktemp -d)
ffmpeg -loglevel error -y -ss 6 -i "$OUT/clip.mp4" -t 2 \
  -vf "scale=640:360,transpose=2" -c:v libx264 -crf 24 -pix_fmt yuv420p -c:a copy "$TMP/small.mp4"
ffmpeg -loglevel error -y -display_rotation:v:0 -90 -i "$TMP/small.mp4" -c copy "$OUT/clip_rot90.mp4"
rm -rf "$TMP"

# 30 s at full 1080p, not committed: file-mode speed test.
ffmpeg -loglevel error -y -ss 20 -t 30 -i "$SRC" \
  -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k "$LOCAL/clip_1080p_30s.mp4"

ls -la "$OUT" "$LOCAL"

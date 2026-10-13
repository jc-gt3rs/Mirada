#!/usr/bin/env bash
# Fetches the FLX checkpoints (BSD-3, Chih-Fan Hsu 2019) used to build Mirada's
# bundled model. Only needed to re-run tools/convert_flx.py. Output is gitignored.
set -euo pipefail
cd "$(dirname "$0")"
DEST=upstream
URL=https://github.com/WangWilly/gaze-correction-cam/releases/download/v0.1.1/weights.zip
# SHA-256 of the checkpoint data files as committed in chihfanhsu/gaze_correction.
EXPECTED_L=f3fc192fef20f56ff9ff39966c6b7fa650a7122df2e406daaa84fc7b8e426e2b
EXPECTED_R=b978676480ecdb8c8134b8c033aa6ee959a40401b3d5492aa99003f9e37843c3

mkdir -p "$DEST/zip" "$DEST/weights"
[ -f "$DEST/zip/weights.zip" ] || curl -fL --retry 3 -o "$DEST/zip/weights.zip" "$URL"
unzip -oq "$DEST/zip/weights.zip" -d "$DEST/weights"

L=$(find "$DEST/weights" -path '*flx/12/L/L.data-00000-of-00001')
R=$(find "$DEST/weights" -path '*flx/12/R/R.data-00000-of-00001')
got_l=$(shasum -a 256 "$L" | cut -d' ' -f1)
got_r=$(shasum -a 256 "$R" | cut -d' ' -f1)
[ "$got_l" = "$EXPECTED_L" ] || { echo "L checkpoint hash mismatch: $got_l" >&2; exit 1; }
[ "$got_r" = "$EXPECTED_R" ] || { echo "R checkpoint hash mismatch: $got_r" >&2; exit 1; }
echo "FLX checkpoints OK in $(dirname "$(dirname "$L")")"

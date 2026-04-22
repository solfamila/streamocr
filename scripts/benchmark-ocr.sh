#!/usr/bin/env bash
# Benchmark the deterministic font-template OCR path.
#
# Usage: scripts/benchmark-ocr.sh [path/to/video.mp4]
# Default video path: $HOME/Downloads/streamocr/pullback_first_2min_1080p.mp4

set -euo pipefail

cd "$(dirname "$0")/.."

VIDEO="${1:-$HOME/Downloads/streamocr/pullback_first_2min_1080p.mp4}"
RUNTIME_CONFIG="Examples/offline/runtime-config.plrz-positions.json"
EXPECTED="Examples/offline/expected-output.plrz-positions.json"
OUT_DIR="Examples/offline"
RESULT_JSON="$OUT_DIR/offline-result.bench-font-template.json"
DIAG_DIR="$OUT_DIR/font-template-diag"
STDERR_LOG="$OUT_DIR/stderr-font-template.log"

if [[ ! -f "$VIDEO" ]]; then
    echo "ERROR: video not found at $VIDEO" >&2
    echo "Pass the path as the first argument." >&2
    exit 1
fi

echo "==> swift build -c release"
swift build -c release

echo ""
echo "==> OCR: font-template matcher"
echo "    Result:  $RESULT_JSON"
echo "    Diag:    $DIAG_DIR (PNGs + font-info.txt)"
mkdir -p "$DIAG_DIR"

start_ns=$(date +%s)
FONT_TEMPLATE_DIAG_DIR="$DIAG_DIR" .build/release/CaptureShellApp --offline-analyze \
    --video "$VIDEO" \
    --runtime-config "$RUNTIME_CONFIG" \
    --expected-output "$EXPECTED" \
    --result-json "$RESULT_JSON" \
    --strict-verify 2> "$STDERR_LOG"
elapsed=$(( $(date +%s) - start_ns ))

echo ""
echo "==== Benchmark summary ===="
printf "%-34s  %-6s  %s\n" "ocr" "time" "result"
printf "%-34s  %-6s  %s\n" "---" "----" "------"
printf "%-34s  %-6s  %s\n" "font-template" "${elapsed}s" "$RESULT_JSON"

echo ""
echo "==== Trigger events ===="
/usr/bin/python3 - <<PY
import json
p = "$RESULT_JSON"
d = json.load(open(p))
print("verification:", d.get("verification", {}).get("matched"))
for event in d.get("triggerEvents", []):
    print(
        f"frame={event.get('frameNumber')} "
        f"t={event.get('presentationTimeSeconds'):.6f} "
        f"value={event.get('parsedInteger')} "
        f"raw={event.get('rawText')!r} "
        f"confidence={event.get('confidence'):.3f}"
    )
PY

echo ""
echo "==== Font resolution (stderr) ===="
grep -E '^\[FontTemplate\]' "$STDERR_LOG" || echo "  (no FontTemplate log lines)"

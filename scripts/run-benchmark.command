#!/usr/bin/env bash
# Double-click target: runs the OCR benchmark from Finder.
# Logs everything to scripts/run-benchmark.log so it's easy to read later.

set -euo pipefail
cd "$(dirname "$0")/.."

LOG="scripts/run-benchmark.log"
echo "=== benchmark run @ $(date) ===" | tee "$LOG"
bash scripts/benchmark-ocr.sh 2>&1 | tee -a "$LOG"
echo "=== done. full log: $LOG ==="
# Keep the Terminal window open so the user can read the output.
echo ""
echo "Press any key to close this window..."
read -r -n 1 _

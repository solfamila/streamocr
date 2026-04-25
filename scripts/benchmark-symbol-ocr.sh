#!/usr/bin/env bash
# Benchmark manualSymbolCell recognition through the same recognizer path used by
# the pipeline, comparing CPU decoding with the Metal symbol matcher.

set -euo pipefail

cd "$(dirname "$0")/.."

ITERATIONS="${1:-500}"

OCR_SYMBOL_BENCHMARK=1 \
OCR_SYMBOL_BENCHMARK_ITERATIONS="$ITERATIONS" \
swift test -c release --filter benchmarkSymbolRecognitionCPUVersusMetalWhenRequested

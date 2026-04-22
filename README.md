# CaptureShellApp

macOS capture and offline-analysis app for the trading stream OCR workflow.

The OCR stack has been intentionally reduced to one method: deterministic
Apple SD Gothic Neo font-template matching. There is no Vision OCR, Core ML OCR,
or hybrid fallback path in the runtime.

Current status:
- Live path captures the display with ScreenCaptureKit.
- Offline MP4 analysis uses the same ROI/OCR/trigger pipeline as live capture.
- Numeric position cells are read with Apple SD Gothic Neo digit templates.
- Optional symbol cells are read with Apple SD Gothic Neo uppercase-letter templates.
- Offline verification can compare recognition events and downstream BUY/subscribe trigger events.

## Offline Workflow

1. Export a reference frame from an MP4 so you can inspect the exact pixels you want to target.
2. Create a runtime config JSON describing the position ROI and optional symbol ROI against that frame size.
3. Run offline analysis on the MP4.
4. Optionally compare the observed OCR/trigger sequence with a known-good expected-output JSON.

### Export a Reference Frame

```bash
swift run CaptureShellApp \
  --offline-export-frame \
  --video /absolute/path/input.mp4 \
  --at-seconds 12.5 \
  --output-png /absolute/path/reference.png
```

### Analyze an MP4 Offline

```bash
swift run CaptureShellApp \
  --offline-analyze \
  --video /absolute/path/input.mp4 \
  --runtime-config /absolute/path/runtime-config.json \
  --expected-output /absolute/path/expected-output.json \
  --result-json /absolute/path/offline-result.json \
  --strict-verify
```

Notes:
- `--strict-verify` exits with code `2` when expected output is provided and verification fails.
- `--result-json` is optional; without it the result JSON is printed to stdout.
- `runtime-config.json` uses the source frame size as its coordinate system.

### Analyze the Live Stream

```bash
swift run CaptureShellApp \
  --live-analyze \
  --seed-url 'wss://bintu-h5live.nanocosmos.de/h5live/stream/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=433201&pid=72860723635' \
  --runtime-config /absolute/path/runtime-config.json \
  --run-seconds 5 \
  --result-json /tmp/live-result.json
```

The live command derives the nanocosmos HTTP `stream.mp4` URL from the `wss://`
seed, decodes frames with AVFoundation, and feeds those frames through the same
OCR pipeline as offline analysis. It is dry-run by default: BUY/subscribe
messages are discarded unless `--send-trading-messages` is explicitly supplied.

### Benchmark the PLRZ Fixture

```bash
scripts/benchmark-ocr.sh
```

The script builds a release binary, runs the PLRZ offline fixture, writes the
result JSON, and dumps the resolved Apple SD Gothic Neo templates for inspection.

## JSON Templates

Sample templates live in:
- `Examples/offline/runtime-config.sample.json`
- `Examples/offline/expected-output.sample.json`

`expected-output.json` supports two optional sections:
- `recognitionEvents`
- `triggerEvents`

Each expected event can match on any subset of:
- `kind`
- `frameNumber`
- `region`
- `action`
- `rawText`
- `normalizedText`
- `symbol`
- `parsedInteger`
- `presentationTimeSeconds`
- `presentationTimeToleranceSeconds`

That makes it possible to write strict regression fixtures or looser "only the meaningful fields matter" checks.

## OCR Design

The recognizer renders Apple SD Gothic Neo glyph templates with Core Text, binarizes the selected ROI, segments the foreground into glyph-like columns, and matches each segment to the rendered template set.

For the numeric position cell, the allowed characters are `0-9`, comma, and period. For the symbol cell, the allowed characters are `A-Z`.

The pipeline still fingerprints each ROI so unchanged frames avoid repeated OCR work. If the numeric cell is unchanged, the cached recognition is replayed into the trigger state machine so multi-frame confirmation still works without rerunning OCR.

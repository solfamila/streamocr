# CaptureShellApp

This repo is being refactored from display OCR toward a video-native OCR pipeline that can be exercised both live and offline.

Current status:
- Live path still uses ScreenCaptureKit for on-screen capture.
- Shared OCR pipeline now accepts generic video frames instead of only display sample buffers.
- Offline MP4 analysis is available and uses the same ROI/OCR/trigger pipeline as the live path.
- Offline verification can compare both OCR recognition events and downstream BUY/subscribe trigger events.

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

That makes it possible to write strict regression fixtures or looser “only the meaningful fields matter” checks.

## Next Steps

- Replace ScreenCaptureKit live ingest with direct stream/HLS ingest.
- Add frame-based ROI selection from decoded video instead of the desktop.
- Swap the default Vision recognizer for specialized Core ML recognizers:
  - numeric-only for the position cell
  - uppercase-letter-only for the symbol cell
  - `.all` compute units where supported

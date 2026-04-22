# CaptureShellApp

macOS capture and offline-analysis app for the trading stream OCR workflow.

The OCR stack has been intentionally reduced to one method: deterministic
font-template matching. There is no Vision OCR, Core ML OCR, or hybrid fallback
path in the runtime.

Current status:
- Live stream analysis decodes network video with AVFoundation and can optionally save a decoded MP4 artifact.
- Offline MP4 analysis uses the same ROI/OCR/trigger pipeline as live capture.
- Numeric position cells are read with Apple SD Gothic Neo digit templates.
- Optional symbol cells are read with Microsoft Sans Serif uppercase-letter templates.
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
  --record-video /tmp/live-source.mp4 \
  --record-audio \
  --live-metadata-json /tmp/live-metadata.json \
  --result-json /tmp/live-result.json
```

The live command derives the nanocosmos HTTP `stream.mp4` URL from the `wss://`
seed, prefers a direct `ffmpeg` decode path for live frames, and falls back to
AVFoundation only if the direct decoder cannot produce video. Those decoded
frames feed the same OCR pipeline as offline analysis. The CLI live analyzer is
dry-run only: it records and analyzes, but does not place trades.
If `--record-video` is set, the app starts a parallel ffmpeg recorder against
the Nanocosmos source URL while OCR keeps decoding frames independently. That
recorder is source-level, much closer to the Python forensics recorder than the
older decoded-frame MP4 writer. If `--record-audio` is also supplied, the same
source recording keeps the audio track instead of capturing and muxing audio
separately. If `--live-metadata-json` is omitted but `--record-video` is set, a
sibling `*.metadata.json` file is written automatically.
The AppKit capture window is the path that routes OCR `BUY` / `SUBSCRIBE`
signals directly into the in-process trading runtime.

### Benchmark the PLRZ Fixture

```bash
scripts/benchmark-ocr.sh
```

The script builds a release binary, runs the PLRZ offline fixture, writes the
result JSON, and dumps the resolved font templates for inspection.

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

Expected events are matched as an ordered subsequence of the actual output.
That means extra actual events are allowed, but expected events still need to
appear in order. Field-level matching is still partial, so fixtures can stay
tight or loose depending on which fields they specify.

## OCR Design

The recognizer renders Core Text glyph templates, binarizes the selected ROI,
segments the foreground into glyph-like columns, and matches each segment to
the rendered template set.

For the numeric position cell, the allowed characters are `0-9`, comma, and
period in Apple SD Gothic Neo. For the symbol cell, the allowed characters are
`A-Z` in Microsoft Sans Serif.

OCR-side symbol normalization is strict, and the same validation is enforced at
the transport boundary too. If OCR had to drop any alphanumeric character to
get from the raw read to a ticker, that candidate is rejected instead of being
laundered into a plausible symbol.

The pipeline still fingerprints each ROI so unchanged frames avoid repeated OCR
work. If the numeric cell or sampled symbol cell is unchanged, the cached
recognition is replayed into the trigger state machine so multi-frame
confirmation still works without rerunning OCR.

In live JSON results, `playbackURL` is the actual URL used by the active live
decoder. With the direct decoder path, that is usually the resolved
`stream.mp4?...` source derived from the seed. If the analyzer falls back to
AVFoundation, `playbackURL` can be the playlist URL instead. `streamURL`
remains the resolved media segment URL from the playlist.

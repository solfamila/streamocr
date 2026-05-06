# CaptureShellApp

macOS capture and offline-analysis app for the trading stream OCR workflow.

The OCR stack has been intentionally reduced to one method: deterministic
font-template matching. There is no Vision OCR, Core ML OCR, or hybrid fallback
path in the runtime.

Current status:
- Live stream analysis prefers a Nanocosmos source-chunk decode path for `stream.mp4` feeds and can optionally save a source-level MP4 artifact.
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
  --live-metadata-json /tmp/live-metadata.json \
  --result-json /tmp/live-result.json
```

The live command derives the nanocosmos HTTP `stream.mp4` URL from the `wss://`
seed and uses a native source-chunk decode path for Nanocosmos streaming MP4
feeds. If that source-chunk path is unavailable, the analyzer falls back to
AVFoundation playback. Those decoded frames feed the same OCR pipeline as
offline analysis. The CLI live analyzer is dry-run only: it records and analyzes,
but does not place trades.
If `--record-video` is set, the app starts a parallel native source recorder
against the Nanocosmos source URL while OCR keeps decoding frames independently.
That recorder is source-level, much closer to the Python forensics recorder than
the older decoded-frame MP4 writer. Streaming MP4 source recording preserves the
source tracks, so audio remains present whenever the source provides it. The old
`--record-audio` flag is gone because source recording already keeps the source
audio track automatically. If `--live-metadata-json` is omitted but
`--record-video` is set, a sibling `*.metadata.json` file is written automatically.
There are three live OCR paths in the app:
- CLI `--live-analyze`: dry-run analysis / JSON / optional recording only
- Trading GUI live stream: routes OCR observations through the central
  `OCRTradingCoordinator`, then executes typed `BUY` / `SELL` / `SUBSCRIBE`
  commands directly against the in-process `TradingRuntimeManager`; real GUI
  trading also emits terminal transport outcome trigger events
- Display capture window: routes ScreenCaptureKit OCR through the same
  coordinator/executor path

The trading GUI also has a separate **Start Recording** / **Stop Recording**
button under the live URL controls. It records the current live URL with the same
native source recorder used by `--record-video`, independent of whether live OCR
is running. GUI recordings are saved as timestamped MP4 files under
`~/Movies/StreamOCR Recordings/`, with a sibling `*.metadata.json` file.

In the trading GUI live-stream path, OCR `SUBSCRIBE` updates the active symbol
in the runtime, and OCR `BUY` uses the configured OCR buy ratio to size the
order (`ocr shares * ratio`, rounded down, minimum 1 share). A live OCR `BUY`
is only actually submitted when controller trading is armed. When disarmed, the
signal is intentionally ignored instead of placing a delayed order later.
After a submitted OCR `BUY`, the numeric position cell is tracked as an
open-position high-water mark. Rising or flat OCR quantities are ignored; the
first safe numeric decrease emits `sell_triggered` and routes a close-long
`SELL` through the runtime. Ambiguous position reads such as unsafe `5`/`6`
near-ties are rejected as `?`, so they do not size BUY orders, rearm BUY, or
trigger SELL.
When a confirmed symbol change commits, manual-cell BUY/SELL state is cleared
and any pending BUY/SELL command for the prior symbol generation is made stale, so
position peaks cannot bleed from one ticker into the next. Real trading
BUY/SELL automation requires a committed OCR symbol and is suppressed while a
symbol refresh or subscribe transition is still pending; after the new symbol
commits, the numeric cell is re-armed and must pass the normal confirmation
threshold before a new-symbol BUY can fire.
SELL detection also requires a minimum numeric OCR confidence and ignores
implausible dropped-digit decreases, such as a five-digit position briefly
reading as a much smaller four-digit number.
Stopping live OCR moves the GUI through a stopping/draining state until pending
OCR trading tasks finish or time out. Stop prevents new or not-yet-submitted OCR
actions; it cannot cancel an order after the app has already crossed into
`submitBuyAsync`.
Display capture uses the same OCR trading coordinator. Stopping capture cancels
pending OCR actions for that capture session, drains them before reporting fully
stopped, and starts the next capture session with a fresh coordinator/session
generation.

Both live and offline result JSON now include `buySignalTimings`, which lists
each `buy_triggered` event with the media `presentationTimeSeconds` and the
wall-clock `analysisTimeSeconds` from the start of that run.

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

The live GUI and display-capture trading paths use typed OCR trading commands
internally. JSON remains the CLI/result/fixture format; runtime trading no
longer routes through JSON message strings.
The central `OCRTradingCoordinator` owns symbol/manual/session state and returns
explicit effects: commands to start and command IDs to cancel. Retryable
BUY/SELL rejections are cooled down in that reducer for one second, so an
unchanged OCR frame cannot hammer the runtime while the broker/gateway is still
recovering. When the symbol state becomes uncertain, pending manual BUY/SELL
commands are cancelled before they can keep walking toward submission. If the
symbol changes again while a `SUBSCRIBE` command is still pending, that stale
subscribe command is cancelled too, so a late completion cannot commit the app
to a symbol that is no longer on-screen.
The low-latency pipeline assembles synchronous symbol/manual OCR into one
`OCRTradingFrameObservation` per frame. Asynchronous symbol OCR still emits a
pending symbol observation first, then a recognized-symbol update when the
background OCR result returns.

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
work. In the GUI live/display paths, the symbol ROI is fingerprinted every
frame; if that fingerprint changes, manual BUY/SELL evaluation is suppressed
immediately until symbol OCR confirms or revalidates the ticker. If the numeric
cell or sampled symbol cell is unchanged, cached recognition can still feed the
active trigger/coordinator path so multi-frame confirmation works without
rerunning OCR. Symbol OCR also forces a fresh read at least every 10 seconds,
even when the symbol-cell fingerprint looks unchanged, so a stale ticker cannot
persist indefinitely because of cache replay.
Confirmed high-confidence symbol changes use the normal confirmation cadence.
Lower-confidence but still valid changed symbols are not ignored forever; they
must repeat for extra confirmations before the coordinator trusts them as a new
ticker. Extremely low-confidence or invalid changed symbols remain suppressed.

In live JSON results, `playbackURL` is the actual URL used by the active live
decoder. With the direct decoder path, that is usually the resolved
`stream.mp4?...` source derived from the seed. If the analyzer falls back to
AVFoundation, `playbackURL` can be the playlist URL instead. `streamURL`
remains the resolved media segment URL from the playlist.

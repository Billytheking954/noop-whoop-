# Night Lab

Night Lab is the local-first evidence and replay layer for NOOP's next sleep system.

The first phase deliberately does **not** change the shipped sleep classifier. It creates a trustworthy
record of what the device actually supplied, what was derived later, and what external reference labels
were imported for evaluation.

## Why this exists

A sleep model is only as useful as the evidence we can replay. NOOP already persists decoded streams and
has a transient raw-frame outbox, but transient capture is not a permanent scientific record. Night Lab
adds a separate, write-once archive for nights chosen for research and algorithm development.

The core rule is simple:

> Raw evidence is captured once. Algorithms may be rerun forever. Reference answers never become inputs.

## Archive layout

Each night owns one directory:

```text
NightLab/<night-id>/
  manifest.json
  raw/
    ... immutable capture assets ...
  derived/
    ... versioned algorithm runs ...
  references/
    ... WHOOP, PSG, or manual comparison labels ...
```

`raw/`, `derived/`, and `references/` are deliberately separate namespaces.

## Manifest

`NightRecordManifest` records:

- schema version
- stable night ID
- recording/sealed state
- capture window
- timezone offset
- source device ID, model, and firmware when known
- WhoopStore schema marker when known
- source-stream fingerprint that bracketed the snapshot
- NOOP version when known
- every raw asset, its signal kind, time span, sample count, cadence when known, and integrity digest

Schema v2 adds source provenance. The new fields are optional so schema-v1 archives remain readable; a
legacy archive says `nil` for provenance it never recorded rather than inventing a value after the fact.

A night can be incomplete and still be honest. Missing motion is represented as missing motion, not as
invented zeros or a fabricated 100% quality score.

## Recording versus sealed

A recording night can gain new raw assets while capture is in progress.

A sealed night is immutable. Every raw asset in a sealed manifest must carry an integrity digest. The
`NightLabFileStore` refuses replacement of existing raw assets and rechecks every SHA-256 digest before a
night is sealed.

Derived results and reference labels may be added later without changing the sealed raw evidence.

## Bridge from WhoopStore

`NightLabStoreBridge` snapshots the durable decoded streams NOOP already uses for sleep analysis. It reads
through WhoopStore's public APIs instead of reimplementing SQLite queries, so Night Lab inherits the same
source-policy decisions as production scoring.

The first bridge captures:

- heart rate from `hrSamples` (measured HR with NOOP's normal PPG fallback policy)
- R-R intervals from `rrIntervals`, including transport/source provenance and emission order
- 1 Hz gravity/motion rows from `gravitySamples`, including `dynAccel` when present
- respiration rows from `respSamples`
- sparse standard-BLE wrist/contact state changes from `standardHRContacts`

The Night Lab window is half-open, `[start, end)`. WhoopStore's stream readers use inclusive upper bounds,
so the bridge translates the read to `to = end - 1`. A sample exactly at wake/end therefore cannot leak
into the archived night.

### Consistent snapshots while offload is running

Historical offload can add old rows while a snapshot is being read. The bridge therefore reads a source
witness before and after fetching the streams. The witness combines:

- `dayStreamFingerprint` for PPG fallback, R-R, gravity, respiration, events, source policy, and registry
- `hrFingerprint` for the measured-HR table that `dayStreamFingerprint` intentionally does not include

If the two witnesses differ, the read is discarded and retried. A Night Lab night is never intentionally
assembled from two different committed database states.

The bridge also fetches one row beyond its configured per-stream limit. If that extra row exists it throws
an explicit `rowLimitExceeded` error before creating an archive instead of silently truncating evidence.

### Durable decoded data is not the same as raw high-rate capture

This bridge snapshots the durable decoded streams currently stored by NOOP. It does **not** pretend that a
1 Hz `GravitySample` is a 100 Hz raw IMU trace, and it does not invent high-rate PPG/accelerometer samples
that are absent from the durable store.

Raw/high-rate Night Lab capture remains a separate source path. `NightHighRateCoverage` already exists for
those assets once an actual raw capture is attached.

## Typed archive loader

`NightLabArchiveLoader` is the reverse side of the bridge. It turns a sealed archive back into the same
protocol-level row types the sleep engine accepts:

- `[HRSample]`
- `[RRInterval]`
- `[GravitySample]`
- `[RespSample]`
- `[NightLabWristStatusRow]`

The loader never reads `references/`. Before returning rows it:

1. requires the night to be sealed;
2. reads every asset through `NightLabFileStore.rawData`, which verifies SHA-256;
3. checks the stored signal kind;
4. checks decoded row count against the manifest;
5. rejects any decoded timestamp outside the manifest's half-open night window.

Coverage used for replay is recomputed from these verified archived rows, so replay describes the exact
sealed bytes rather than trusting a transient capture-time report.

## Signal coverage

Coverage is calculated per signal, never as one magical quality number that hides what went missing.

For ordinary second-resolution streams, `NightSignalCoverage` reports true row count, expected count when
a cadence is known, coverage fraction, gap count, and largest gap. Temporal coverage uses unique timestamp
seconds while `sampleCount` remains the true number of rows; this distinction matters for R-R, where several
real beats may share one timestamp second.

For high-rate signals such as 100 Hz accelerometer/gyro/optical capture, use `NightHighRateCoverage`, which
works in milliseconds and preserves multiple samples per second.

If expected cadence is unknown or the signal is event-driven, coverage percentage is deliberately `nil`.
The system must not manufacture precision it does not have. Wrist/contact state is sparse state-change data,
so it also gets no fabricated per-second coverage percentage or gap count.

## Replay and algorithm versioning

Every replay run records `NightAlgorithmIdentity`:

- algorithm ID
- semantic/version string
- optional build/commit identifier

This allows the same sealed night to be run through several engines without changing the source evidence.
For example:

```text
Night 2026-09-13
  raw evidence
  derived/
    sleep-v2 2.0.0
    sleep-v2 2.1.0
    experimental-rem 0.1.0
```

## Blind reference rule

`NightReplayInput` contains the raw manifest and raw-derived coverage only.

It intentionally has no WHOOP, PSG, manually entered stage, sleep score, recovery score, REM total, deep
total, light total, or other answer field.

External truth/reference data uses `NightReferenceLabels` and is joined only **after** an algorithm run for
evaluation.

This is the most important Night Lab invariant. It prevents accidental answer leakage in blind tests.

## References are not medical ground truth

A provider label records where a comparison came from. WHOOP output can be useful as a reference, but it
is not treated as medical ground truth. PSG-grade labels, when available and legally/ethically obtained,
should remain distinguishable from consumer-wearable labels.

## Phase 1 completion checklist

- [x] Night manifest contract
- [x] raw/reference/derived namespace contract
- [x] sealed-night integrity requirement
- [x] second-resolution signal coverage
- [x] high-rate signal coverage
- [x] algorithm identity/version contract
- [x] blind replay input contract
- [x] external reference-label contract
- [x] unit tests for the contracts above
- [x] write-once on-device archive implementation
- [x] bridge existing NOOP decoded sleep streams into a Night Lab night
- [x] typed sealed-archive loader for deterministic replay
- [ ] replay adapter for the current sleep stager
- [ ] developer UI for viewing a night's signal coverage
- [ ] export/import of a complete Night Lab bundle

The unchecked items are intentionally implementation work, not promises hidden in a data model.

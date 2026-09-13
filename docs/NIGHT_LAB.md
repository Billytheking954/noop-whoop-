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
    sleep_stager_v2_baseline.json
    executions/
      ... non-deterministic timing receipts ...
    ... other versioned algorithm runs ...
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
2. reads each typed replay asset through `NightLabFileStore.rawData`, which verifies SHA-256;
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

## SleepStagerV2 production baseline replay

`SleepStagerV2ReplayAdapter` establishes a reproducible baseline for the current production session stager.
It does not run session detection, and it does not change or copy the private V2 classifier.

The path is:

```text
sealed archive
  -> NightLabArchiveLoader
  -> NightLabArchivedStreams
  -> SleepStagerV2ReplayAdapter
  -> SleepStagerV2.stageSession(...)
  -> untouched [StageSegment]
  -> deterministic 30-second canonicalisation
  -> derived/sleep_stager_v2_baseline.json
```

The production call receives the archived gravity, HR, R-R, and respiration arrays exactly. Wrist/contact
state remains archive provenance but is not passed into V2 because the production API has no wrist/contact
argument.

### Baseline window and epoch grid

This baseline stages exactly:

```text
[manifest.windowStartUnix, manifest.windowEndUnix)
```

It deliberately does not invoke V1/session detection. Detection remains a separate later layer.

V2's internal evaluation epochs are anchored to absolute Unix multiples of 30 seconds, so the baseline
records:

```text
epochSeconds = 30
epochAnchorUnix = 0
```

If a session begins between grid boundaries, Night Lab stores that first fragment separately as
`leadingBoundary` rather than pretending it is a full 30-second epoch. Aligned epochs are expanded from the
public production `StageSegment` output, and the final epoch is clipped to the real half-open session end.
Nothing is generated beyond the Night Lab window.

The untouched production segments are stored alongside the expanded epochs so an audit can distinguish a
staging change from a canonicalisation defect.

Canonicalisation accepts only `wake`, `light`, `deep`, and `rem`. Unknown labels, invalid segments, gaps,
overlaps, incomplete window coverage, or non-grid interior V2 transitions fail loudly rather than being
silently mapped to a convenient answer.

### Implementation identity

Every baseline records two supplied identities:

- the NOOP repository commit SHA;
- the exact `SleepStagerV2.swift` source/blob SHA.

`SleepStagerV2ImplementationIdentity` receives these from the caller/build layer. Night Lab does not invent
or hard-code a commit SHA. Keeping both values lets us tell an unrelated repository change from an actual
stager-source change.

### Input provenance

The baseline stores the sealed archive's raw asset identities in stable asset-ID order, including asset ID,
signal kind, SHA-256, sample count, and whether production V2 consumes that asset. Manifest source
fingerprint, device/model, firmware, store schema, NOOP version, timezone, and manifest schema are preserved
when available. Legacy schema-v1 fields remain `nil` instead of being reconstructed after the fact.

### Deterministic baseline versus execution receipt

The canonical baseline contains no wall-clock execution time and no measured run duration. Therefore the
same sealed archive plus the same implementation identity produces the same JSON bytes and SHA-256.

`NightLabFileStore.saveDeterministicDerivedArtifact` uses this contract:

- absent file -> atomic create;
- existing byte-identical file -> success with the same SHA-256;
- existing different bytes -> `derivedArtifactConflict`;
- never overwrite the canonical baseline.

Execution timing is saved separately as `SleepStagerV2ExecutionReceipt` under `derived/executions/`. Its
wall-clock timestamp and monotonic duration may change from run to run without contaminating the baseline.

### Blind-reference isolation

Neither `SleepStagerV2ReplayAdapter` nor `NightLabSleepStagerV2BaselineRunner` has an API for loading
`references/`. The adapter receives only `NightLabArchivedStreams` and implementation identity.

A regression test writes a WHOOP reference, runs the baseline, adds a contradictory WHOOP reference, reruns,
and requires identical baseline bytes and SHA-256. Reference labels remain evaluation evidence only.

### Scope note: surrounding context

Production V2 can use supplied HR/R-R/motion rows outside the staged session in centred feature windows near
the edges. The current Night Lab stored-data bridge intentionally seals only its chosen `[start,end)` evidence.
This baseline therefore means exactly:

> current production SleepStagerV2 executed on the sealed Night Lab inputs.

It does not claim to reconstruct an earlier live staging call that may have received additional pre/post
session rows. If exact runtime-call parity becomes necessary, that surrounding context must be captured as
explicit evidence rather than invented during replay.

### Running a baseline

```swift
let implementation = SleepStagerV2ImplementationIdentity(
    noopCommitSHA: suppliedCommitSHA,
    stagerSourceBlobSHA: suppliedSleepStagerV2BlobSHA
)

let result = try await NightLabSleepStagerV2BaselineRunner.run(
    archive: archive,
    nightID: nightID,
    implementation: implementation
)
```

`result.baselineFile.sha256` is the deterministic baseline identity. `result.receipt` describes that one
execution's timing.

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
    sleep_stager_v2_baseline.json
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
- [x] replay adapter for the current SleepStagerV2 session stager
- [x] deterministic canonical V2 baseline artifact + separate execution receipts
- [ ] developer UI for viewing a night's signal coverage
- [ ] export/import of a complete Night Lab bundle

The unchecked items are intentionally implementation work, not promises hidden in a data model.

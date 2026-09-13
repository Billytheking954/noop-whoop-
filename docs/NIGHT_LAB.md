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
- source device model and firmware when known
- NOOP version when known
- every raw asset, its signal kind, time span, sample count, cadence when known, and integrity digest

A night can be incomplete and still be honest. Missing motion is represented as missing motion, not as
invented zeros or a fabricated 100% quality score.

## Recording versus sealed

A recording night can gain new raw assets while capture is in progress.

A sealed night is immutable. Every raw asset in a sealed manifest must carry an integrity digest. Future
storage code must refuse attempts to replace a sealed raw asset.

Derived results and reference labels may be added later without changing the sealed raw evidence.

## Signal coverage

Coverage is calculated per signal, never as one magical quality number that hides what went missing.

For ordinary second-resolution streams, `NightSignalCoverage` reports sample count, expected count when a
cadence is known, coverage fraction, gap count, and largest gap.

For high-rate signals such as 100 Hz accelerometer/gyro/optical capture, use `NightHighRateCoverage`, which
works in milliseconds and preserves multiple samples per second.

If expected cadence is unknown or the signal is event-driven, coverage percentage is deliberately `nil`.
The system must not manufacture precision it does not have.

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
- [ ] write-once on-device archive implementation
- [ ] bridge existing NOOP decoded streams into a Night Lab night
- [ ] replay adapter for the current sleep stager
- [ ] developer UI for viewing a night's signal coverage
- [ ] export/import of a complete Night Lab bundle

The unchecked items are intentionally implementation work, not promises hidden in a data model.

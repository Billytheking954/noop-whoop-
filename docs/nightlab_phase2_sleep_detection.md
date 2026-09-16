# Night Lab Phase 2A — sleep detection contract

Phase 2A creates an experimental, deterministic boundary-detection seam on top of the sealed Night Lab archive.
It does **not** replace production sleep detection and it does **not** modify `SleepStagerV2`.

## Bootstrap path

`NightLabSleepDetectorV2.detect(...)` still uses the existing V1 Stage-0 detector (`SleepStager.detectSleep`) as its candidate spine, then projects the result to detection-only boundaries. This preserves the existing false-positive, sparse-data and off-wrist guards while the replay/validation contract remains stable.

That bootstrap path is intentionally still identified as:

- algorithm: `nightlab.sleep-detection-v2`
- version: `0.1.0-bootstrap-v1-spine`
- candidate source: `SleepStager.detectSleep.stage0-v1`

It is not presented as a new independent physiological classifier.

## Independent experimental shadow detector

Phase 2 now also contains a second candidate generator that does **not** call the V1 sleep detector:

- algorithm: `nightlab.sleep-detection-v2-independent`
- version: `0.2.0-motion-hr-shadow`
- candidate source: `nightlab.motion-hr-window-v1`

The independent path is shadow-only. It is not connected to production sleep-session selection and does not stage sleep.

Its current design is deliberately conservative:

1. HR and gravity are deterministically ordered and duplicate timestamps are canonicalised by the existing Night Lab seam.
2. Gravity-vector changes are summarised in fixed windows.
3. Coverage is measured from actual sample timestamps. Missing motion samples are not interpreted as zero movement.
4. Low-motion windows are defined from the night's own movement distribution rather than a local clock-time rule.
5. A subject-relative awake HR reference is derived only from sufficiently covered high-movement windows.
6. Low-motion candidate runs require adequate gravity coverage, adequate HR coverage, a measurable HR dip relative to that awake reference, and acceptable explicit wrist-off overlap.
7. Short, well-supported candidates can remain separate, allowing naps and split sleep to be measured rather than forcing one overnight block.

If the archive cannot provide motion contrast or an awake HR calibration, the experimental detector returns `insufficientEvidence` rather than fabricating a sleep decision.

The current HR-dip, coverage, window and wrist-off thresholds are **research configuration**, not validated production physiology. They exist so Night Lab can measure behaviour and failure modes. They must not be interpreted as WHOOP's algorithm or as clinically validated sleep thresholds.

## Shadow comparison

Night Lab can run the bootstrap V1-backed seam and the independent experimental detector on the same evidence and record a comparison without declaring a winner.

The comparison records:

- each detector's status
- candidate count
- each primary boundary
- primary start difference
- primary end difference
- primary duration difference
- whether only V1 detected a candidate
- whether only V2 detected a candidate
- candidate-count disagreement
- boundary disagreement

There is deliberately no `V2 wins` result and no automatic promotion decision.

## Contract

For identical detector inputs, configuration and implementation version, boundary results must be deterministic.

The Phase 2 seam provides:

- canonical HR/gravity timestamp ordering
- deterministic duplicate-timestamp handling
- explicit `detected`, `insufficientEvidence`, `noPlausibleSleep`, and `invalidEvidence` outcomes
- all candidate boundaries plus a deterministic primary boundary
- independent HR and gravity gap diagnostics
- structured evidence warnings
- algorithm/configuration identity
- sealed-archive provenance when invoked with `NightLabArchivedStreams`
- an independent shadow candidate generator with its own identity and diagnostics
- explicit V1-vs-V2 comparison output

## Signal use

The bootstrap boundary path currently uses:

- heart rate
- gravity/motion
- validated explicit wrist-off intervals supplied by the caller
- timezone offset through the existing V1 guard

The independent shadow path currently uses:

- gravity-vector movement
- gravity coverage
- heart-rate coverage
- relative HR behaviour against movement-supported awake windows
- validated explicit wrist-off intervals supplied by the caller

The independent path records the timezone for provenance but does not use local clock time to classify sleep.

Night Lab also records the availability of RR, respiration and archived wrist-status rows. They are intentionally not fed into the independent boundary selector yet. Archived wrist-state raw values are not guessed into off-wrist intervals until their semantics are validated and versioned.

## Detection versus staging

Detection answers: **where does the sleep session start and end?**

Staging answers: **what stage occurred inside an already-selected interval?**

Phase 2 keeps those responsibilities separate. `SleepStagerV2` remains unchanged.

## Current adversarial coverage

The independent shadow tests exercise:

- input-order determinism
- duplicate packets
- cross-midnight sleep
- very late sleep
- early sleep
- sedentary daytime-like stillness
- movie/gaming/studying-like stillness without an HR dip
- long explicit wrist-off overlap
- missing accelerometer evidence
- missing HR evidence
- all-still evidence without wake calibration
- short naps
- two separate sleep candidates
- exact +24-hour clock shifts
- benign sampling-density changes
- accelerometer dropouts inside an otherwise sleep-like interval
- non-finite gravity evidence
- V1-vs-V2 shadow comparison

These are synthetic/adversarial tests. They demonstrate implementation properties, not real-world sleep accuracy.

## Promotion rule

Nothing in Phase 2A is a production promotion. The independent detector must demonstrate deterministic replay, safe failure on malformed/sparse evidence, cross-midnight correctness, false-positive resistance and real-night held-out validation before it can even be considered for replacing production behaviour.

Real Night Lab archives should be replayed in shadow mode when repository fixtures become available. If no sealed fixtures are checked in, real-night validation remains blocked rather than being replaced with invented data.

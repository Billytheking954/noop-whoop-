# Night Lab Phase 2A — sleep detection contract

Phase 2A creates an experimental, deterministic boundary-detection seam on top of the sealed Night Lab archive.
It does **not** replace production sleep detection and it does **not** modify `SleepStagerV2`.

## Current bootstrap

`NightLabSleepDetectorV2` currently uses the existing V1 Stage-0 detector (`SleepStager.detectSleep`) as its candidate spine, then projects the result to detection-only boundaries. This deliberately preserves the existing false-positive, sparse-data and off-wrist guards while the replay/validation contract is established.

The bootstrap is not presented as a new independent physiological classifier. A later detector can replace the candidate generator behind the same contract after it has been validated.

## Contract

For identical detector inputs, configuration and implementation version, boundary results must be deterministic.

The seam provides:

- canonical HR/gravity timestamp ordering
- deterministic duplicate-timestamp handling
- explicit `detected`, `insufficientEvidence`, `noPlausibleSleep`, and `invalidEvidence` outcomes
- all candidate boundaries plus a deterministic primary boundary
- independent HR and gravity gap diagnostics
- structured evidence warnings
- algorithm/configuration identity
- sealed-archive provenance when invoked with `NightLabArchivedStreams`

## Signal use

Boundary selection currently uses:

- heart rate
- gravity/motion
- validated explicit wrist-off intervals supplied by the caller
- timezone offset through the existing V1 guard

Night Lab also records the availability of RR, respiration and archived wrist-status rows. They are intentionally not fed into boundary selection yet. Archived wrist-state raw values are not guessed into off-wrist intervals until their semantics are validated and versioned.

## Detection versus staging

Detection answers: **where does the sleep session start and end?**

Staging answers: **what stage occurred inside an already-selected interval?**

Phase 2A keeps those responsibilities separate. `SleepStagerV2` remains unchanged.

## Promotion rule

Nothing in Phase 2A is a production promotion. A future independent detector must demonstrate deterministic replay, safe failure on malformed/sparse evidence, cross-midnight correctness, false-positive resistance and held-out validation before replacing production behaviour.

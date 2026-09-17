# SpO2 evidence status — 2026-09-17

## Conclusion

Scientifically blocked on the available evidence. This is not a validated native SpO2
implementation. Byte 82 remains an experimental historical candidate. The separate
26-byte summary-frame decoder is an **unverified supplied hypothesis**, not an observed
WHOOP protocol contract. Decimal byte value 82 and opcode 0x52 must not be conflated.

The confirmed validation blocker is a missing same-night comparison. The recovered
standalone backup passed SQLite integrity and foreign-key checks. It contains 620,534
v18 auxiliary records, but none in the export's sole sleep window with a reference
blood-oxygen value. The rawBatch and legacy spo2Sample tables both contain zero rows.
The same reference window also has zero HR, RR and sleep-state rows, so this is a
broader retained-data gap, not evidence that only oxygen decoding failed. Its cause
(device capture, sync or retention) cannot be determined from this backup alone.
Other dates' candidate values cannot substitute for missing reference-night data.
This establishes insufficiency of this dataset, not impossibility of decoding WHOOP.
Raw personal data, device identifiers and individual reference values are not committed.

## Pipeline assessment

| Stage | Status | Evidence / boundary |
| --- | --- | --- |
| Device generation | Impossible to verify | No live strap in this session; no raw frames in recovered backup |
| Historical evidence persistence | Verified working for retained dates | 620,534 stored v18 auxiliary records, unpacked through existing codec |
| Reference-night capture | Missing | Zero v18 rows inside the timezone-corrected reference sleep interval |
| Historical byte-82 identity | Unsupported as a measurement | Values exist elsewhere; no paired observation establishes oxygen semantics |
| Summary-frame identity | Unsupported | Synthetic 26-byte fixtures only; no observed hardware capture |
| Timestamp conversion | Fixed tooling defect | Reused offset-aware export parsing; missing overlap persists after correction |
| Scaling/endian/CRC | Structurally testable only | Synthetic decoder tests do not validate real sensor layout or calibration |
| Quality / duplicate handling | Hardened research code | Reject invalid numerical values, conflicts, overlapping epochs and repeated coverage |
| Whole-night aggregation | Hardened research code | Accepted interval union, boundary coverage, matching baseline and contiguous deep-stage evidence |
| Archive import/export | Existing infrastructure reused | Original raw hex asset remains replayable; archive format is unchanged |
| Production SpO2 persistence / UI | Not enabled by this work | No candidate promotion or HealthKit write; diagnostic wording explicitly experimental |

Night Lab inspection reads the optional `whoop5-spo2-summary` asset and uses the existing
manifest/baseline provenance. No observed capture writer for this hypothetical packet
format was identified; it would be misleading to manufacture one from byte-82 records.
The real byte-82 path already retains auxiliary evidence and has a reproducible validator.

## Hypotheses

| Hypothesis | Evidence for | Evidence against / missing | Result |
| --- | --- | --- | --- |
| Wrong scalar scale or endian | Some historical values lie in the expected numerical range | No paired targets; no neighbouring raw bytes to compare | Undetermined; no calibration fitted |
| Byte 82 is another field/status | Multiple raw codes, including out-of-band values, occur | Semantics cannot be established without paired captures | Open competing hypothesis |
| 26-byte 0x52 summary is direct SpO2 | Synthetic fixtures follow that supplied layout | No raw device fixture establishes that layout | Unverified; developer-only |
| Timestamp alignment causes apparent absence | Old harness discarded timezone offsets | Corrected parser still finds zero overlapping records | Tool bug fixed; not the full explanation |
| Incomplete evidence yields plausible nightly result | Prior code counted observations; repeated stages could inflate duration | New regressions target these paths | Confirmed software defects; safeguards implemented |
| Alternative mean/median/lag can recover reference | Existing harness supports candidate comparison | Zero same-night records: any fit would fabricate evidence | Blocked before fitting |
| Derive oxygen from red/IR | Legacy model exists | No optical rows or raw frames in this backup; no validated calibration | Blocked |

## Accuracy

- Reference nights with a value: 1.
- Paired nights: 0; paired-night availability: 0/1.
- MAE, median absolute error, bias, RMSE and correlation: unavailable, not zero.
- Duty-window coverage: unknown; the detected emission is irregular. The validator
  warns that treating individual samples independently may over-weight dense bursts.
- Actual reference-window v18 observation count: zero.
- Neighbour-offset specificity: unavailable from this decoded database.
- Development/holdout split: not possible with zero pairs. No holdout tuning performed.
- Agreement with a WHOOP export would establish interoperability evidence, not clinical accuracy.

## Implementation

- `Packages/WhoopProtocol/Sources/WhoopProtocol/WHOOPSpO2Decoder.swift`: exact frame length;
  trailing bytes are not silently discarded.
- `Packages/WhoopProtocol/Sources/WhoopProtocol/SpO2QualityFilter.swift`: validate finite,
  in-range, raw/decoded-consistent samples even when public initialization or Codable bypasses decoding.
- `Packages/WhoopProtocol/Sources/WhoopProtocol/SpO2Aggregator.swift`: deduplicate before
  filtering; reject conflicting timestamps and overlapping accepted five-minute epochs.
- `Packages/StrandAnalytics/Sources/StrandAnalytics/NightLabSpO2Diagnostics.swift`:
  strict hex, bounded windows, accepted interval coverage, matching baseline windows,
  conservative boundary completeness and non-overlapping, contiguous deep-stage intervals.
- `Strand/Screens/NightLabSpO2DiagnosticsCard.swift`: replace claims of a confirmed
  protocol/measurement with explicit research labels.
- The two corresponding Swift test files preserve the pending adversarial regressions.
- `Tools/linux-capture/validate_spo2_candidate.py`, its three test files and
  `Tools/backup_validation.py` / `Tools/test_backup_validation.py`: reuse the existing
  scoring branch's integrity, timezone, missing-observation and no-overlap fixes;
  add RMSE/median-absolute-error reporting and a regression for opposite signed errors.
- `.github/workflows/swift-packages.yml`: enable the unchanged package test matrix for
  PRs into the Night Lab foundation branch as well as main.

The five-minute, SWS, quality/motion and coverage settings are existing research
assumptions, not newly validated physiology. Exact boundary completeness is deliberately
conservative for this hypothetical frame contract; it must not be applied to duty-cycled
historical byte-82 data. No production Recovery, Sleep, Stress, Strain or HRV coefficients
are changed. No Kotlin counterpart is added: the modified Swift summary-frame/Night Lab
research API has no shipped Kotlin twin; the Python tool is platform-independent and no
shared production stored value or backup format changes.

## Reproduction and validation

Keep inputs private. On a standalone exported database or `.noopbak`:

```sh
python Tools/linux-capture/validate_spo2_candidate.py /private/noop.noopbak /private/whoop.zip --device research-strap --show-nights
python -m unittest discover -s Tools/linux-capture -p 'test*.py'
python -m unittest discover -s Tools -p 'test_backup_validation.py'
swift test --package-path Packages/WhoopProtocol
swift test --package-path Packages/StrandAnalytics
```

The tool distinguishes missing fields, recorded zeroes, out-of-band codes and no
same-night observations. Select `--app-device` when multiple physical devices exist.

Local Python capture suite: 237 tests run, one skipped, no failures. Backup preflight:
10 tests passed. Source hygiene, i18n coverage and diff checks passed.
Swift/Xcode is unavailable locally. Initial remote CI caught an overly complex test
expression; it was split into explicitly typed intermediate values. Replacement Swift
CI is recorded on PR #5; do not infer its result from the local Python tests.
App UI rendering/build and live BLE capture were not run here.

## Next smallest experiment

Capture one ordinary complete night with the existing historical auxiliary/raw capture
path and obtain the official WHOOP export for that exact night, preserving timezone,
strap identity, firmware and missing intervals. First prove nonzero same-night overlap;
then collect multiple development nights and reserve later independent nights before
choosing any scale or aggregation. Retain raw frames for neighbour-field comparisons.
Do not alter breathing or oxygen levels to generate variation. Until independent
validation exists, keep the candidate in developer diagnostics.

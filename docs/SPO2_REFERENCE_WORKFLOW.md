# SpO2 evidence and independent-reference workflow

## Current boundary

WHOOP 5/MG historical byte `@82` is an experimental candidate. Its physiological
meaning, timing, calibration and device/firmware dependence remain unverified.
The separate 26-byte `0x52` decoder is an unverified supplied hypothesis, not a
device-observed replacement for the historical byte. Decimal offset 82 is not a
command identifier. See [the current sensor contract](PROTOCOL_SENSORS.md#r18-biometric-summary).

NOOP already retains the historical candidate in `v18AuxSample`; it is different
from the legacy red/IR `spo2Sample` model. A missing ordinary blood-oxygen value
does not by itself identify a BLE decoding defect. The production value remains
import-based. This work changes offline validation tools, not app metrics,
HealthKit writes, BLE collection, sleep behavior or production coefficients.

The prior investigation recorded **zero paired nights** in the available retained
NOOP data and WHOOP references. That finding does not validate the candidate, nor
does it establish that decoding is impossible. New paired observations are needed.
The previous evidence note on PR #5 is historical; its proposal to collect both
apps' history for the same WHOOP 5 night must not be used for this setup.

WHOOP 5 history is treated as single-consumer here. The workable experiment uses
NOOP as the sole history consumer and an **independent recording oximeter** on the
same wearer during ordinary sleep. It does not use simultaneous app offloads,
withheld acknowledgements, mirrored histories, authentication bypasses or values
copied from WHOOP into the candidate stream. A spot reading on another night
cannot substitute for an aligned recording. Do not intentionally change breathing
or oxygen levels to create variation.

## Software defects addressed

The raw-capture validator accepted frames with a bad CRC whenever their layout
byte was 18. It also accepted unframed synthetic buffers. Candidate validation now
requires the full WHOOP 5 envelope, declared length, header CRC, payload CRC and
124-byte historical v18 layout. Rejections are counted in JSON and text output.
Test fixtures carry valid framing; production code has no test-data exception.

`spo2_reference.py` adds the missing independent-reference path and can inspect a
night without any reference. It reuses the existing archive/SQLite integrity
preflight, device selection and packed `V18AuxCodec` reader. It never indexes
directly into the packed database blob at offset 82. Database URI encoding also
preserves spaces, `#` and `%` in exported filenames.

The independent comparison deliberately does **not** pre-filter asleep nonzero
`@82` values to the exploratory 70–100 range. Doing that would censor evidence
against the direct-percent hypothesis. Every nonzero asleep candidate second stays
in the pairing denominator. A nonzero asleep value outside 70–100 is reported as a
range inconsistency and, when a reference comparison is requested, the result is
`candidate_range_violation` rather than `paired_research_only`. This is a
falsification safeguard, not evidence that 70–100 is the true protocol range.

## First inspect the retained night

Use a standalone exported NOOP database or `.noopbak`, not a live SQLite store.
The window is half-open: its start is included and its end is excluded. Timestamps
accept whole Unix seconds or ISO 8601 with an explicit UTC offset. No timezone is
guessed, and subsecond times are rejected rather than rounded.

From the repository root (replace the example paths and dates):

```sh
python Tools/linux-capture/spo2_reference.py private/noop.noopbak --start 2026-09-20T22:00:00+01:00 --end 2026-09-21T07:00:00+01:00 --output private/capture-report.json
```

Add `--app-device` with the stored device identifier if the backup has multiple
straps. Mixed straps are refused unless one is selected. The report distinguishes:

| Observation | Meaning |
|---|---|
| No retained records | No candidate comparison can be made for that interval |
| Missing field | The packed row did not supply a decodable @82 slot |
| Recorded zero | An observed zero byte, not missing data and not zero oxygen |
| Nonzero out-of-band | Retained raw codes outside the exploratory 70–100 range |
| Unknown sleep state | No matching strap sleep-state row; excluded from asleep comparisons |
| Asleep in-band candidate | An observation inside the exploratory range; not confirmed SpO2 |
| Asleep nonzero candidate | Any nonzero asleep @82 observation; this is the independent-comparison denominator |

Each retained row witnesses only its own second. Gaps are not filled. Sleep-state
code 2 remains the existing research selection. The exploratory 70–100 range is
reported for diagnostics but is no longer used to remove nonzero evidence before
independent pairing. These are research choices, not physiological claims.

## Independent reference input

Normalize an actual device export locally into UTF-8 CSV with exactly these
columns. The following values are **synthetic format examples**, not observations:

```csv
timestamp,spo2_percent,quality
2026-09-20T21:00:00Z,96,valid
2026-09-20T21:00:01Z,,invalid
2026-09-20T21:00:02Z,97,valid
```

`quality` must explicitly be `valid` or `invalid`, based on the source device's
quality indication. Do not mark an unqualified, missing, or contact-lost sample
valid to make the comparison pass. Device-specific CSV conversion is not included;
the actual export format and its quality flags must be checked first. Percentages
must be finite and in `(0,100]`. Reference values below 70 are retained to expose
disagreement instead of being filtered to resemble the candidate. Identical
duplicates are deduplicated; contradictory values or quality at one timestamp
refuse the comparison.

Provide a JSON sidecar with source and clock provenance. These are **user-declared
facts**, not facts the tool can independently verify:

```json
{
  "reference_kind": "independent_oximeter",
  "reference_device": "actual manufacturer and model",
  "reference_firmware": "actual version or unknown",
  "capture_device_model": "WHOOP 5.0",
  "capture_firmware": "actual version or unknown",
  "same_wearer": true,
  "clock_offset_seconds": 0,
  "clock_alignment_note": "Describe how clock alignment was checked independently of the oxygen values",
  "partition": "development"
}
```

`aligned_reference_time = reference_time + clock_offset_seconds`. Declare the
offset from clock observations **before** examining agreement, not by optimizing
correlation. The tool accepts only whole-second offsets within ±300 seconds as a
processing limit. Larger or subsecond discrepancies require checking the source
timestamps; they are not silently rounded. The tool does not enforce prospective
registration: a partition label alone cannot prove an untouched holdout.

```sh
python Tools/linux-capture/spo2_reference.py private/noop.noopbak --start 2026-09-20T22:00:00+01:00 --end 2026-09-21T07:00:00+01:00 --reference-csv private/reference.csv --reference-metadata private/reference.json --output private/comparison.json
```

The command only matches identical aligned seconds. It does not interpolate,
reuse a nearest observation, carry a reading forward or invent a missing night.
This conservative comparison can miss a genuine device response lag: @82's
time-response model is still unknown. It is a diagnostic baseline, not a validated
optimal alignment. Reference data sampled less frequently than the candidate may
fail the completeness policy even when useful exploratory pairs exist.

## Interpretation and reproducibility

Reports include SHA-256 hashes of the original capture, reference CSV and metadata.
An input changing during the run refuses the result. Output files are created
exclusively so a later run cannot silently replace an earlier report. Reports are
local and include dates, source details and aggregate health observations; they
are not automatically safe to post publicly. Raw samples and private captures
must remain outside the repository.

The method identifier is `v18-at82-independent-exact-second-v2`. At least 80% of
nonzero asleep candidate seconds must pair before descriptive differences are
emitted. A result also needs at least two exact-second pairs before availability
can become `paired_research_only`; a single pair is explicitly
`insufficient_paired_samples`. Two pairs are only the mathematical floor needed
for a correlation-style paired comparison, **not** a physiological-validation
sample requirement. Real validation must use substantially more prospectively
specified evidence and independent sessions.

The 80% completeness rule is an explicitly chosen research threshold, not a
clinically validated quality threshold. Counts remain visible when metrics are
unavailable. Reports include both sample-weighted differences and equally weighted
means of contiguous observed candidate runs with at least 80% pairing. A run is
not a claim about the strap's true emission cycle. Repeated seconds and adjacent
runs are not independent nights, and these metrics are not whole-night oxygen
values.

Every result retains `evidence_status: experimental_unvalidated` and
`promotion_allowed: false`, even for perfect correlation. Constant inputs have
undefined correlation, represented by JSON `null`. Zero pairs never produce
zero-valued error metrics. MAE-like differences, bias and RMSE describe agreement
only on matched observations; an independent consumer sensor is not clinical
ground truth. Firmware marked unknown limits reproducibility. Correlation is never
identity proof and is especially vulnerable to shared trends; no lag search is
performed to manufacture a better correlation after the fact.

Further progress requires ordinary, time-aligned recordings over multiple nights
and devices/firmware, raw-frame evidence for competing fields, and development
versus later untouched holdout observations. Evidence must establish what the byte
means before any calibration or promotion. No new personal recording or hardware
validation was performed while implementing these tools.

## Validation and integration

```sh
python -m unittest discover -s Tools/linux-capture -p 'test_*.py'
python -m unittest discover -s Tools -p 'test_backup_validation.py'
python Tools/doc_comment_lint.py
git diff --check
```

Regression cases cover corrupt frames with plausible bytes, unknown layouts,
timezone offsets, wrong-night data, missing versus zero values, gaps, conflicting
duplicates, non-finite references, sample-density bias, input selection, read-only
archive/SQLite analysis, refusing to overwrite reports, nonzero out-of-band
candidate evidence and single-pair insufficiency. All fixtures are synthetic;
these tests validate software behavior, not physiological identity.

The change is based on PR #8 (`fix/repository-audit-20260918`) and preserves its
validation fixes. It does not depend on PR #9's inspection UI work or replace the
older PR #5 review history. Python CI includes stacked PR targets so the tests run
before integration. Python tooling is shared across platforms; no Swift/Kotlin
production algorithm, schema, UI or stored metric changes require a twin here.
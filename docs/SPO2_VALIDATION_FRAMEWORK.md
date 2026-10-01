# SpO2 Validation Framework

## Purpose

This document defines what evidence is needed, what tests must pass, and what is still unverified about the retained WHOOP 5/MG historical oxygen saturation candidate signal (byte @82 / 0x52 summary).

**Current status: EXPERIMENTAL_UNVALIDATED**

- There are retained historical records
- They contain plausible oxygen-like values
- There are ZERO paired reference nights with independent oximeter agreement
- Therefore the signal cannot yet be claimed as valid physiological SpO2

This framework defines the minimal evidence gates required to move from "candidate hypothesis" to "validated signal."

---

## Stage 0: Data Integrity (Already Partially Verified)

Before any physiological claim, the data itself must be trustworthy.

### 0.1 Storage Source Verification
**Goal**: Confirm the retained bytes are exactly what WHOOP 5/MG stored.

**Tests**:
- [ ] Recover the full WHOOP 5/MG backup binary
- [ ] Identify the exact packet structure containing byte @82 in the v18 format
- [ ] Verify CRC/checksum on the entire packet
- [ ] Confirm byte @82 decodes as a 0–100% range value
- [ ] Verify against original device firmware documentation if available
- [ ] Confirm backup integrity: no corruption, no partial writes, no overwrites

**Evidence file**: `references/spo2_backup_integrity_report.json`
```json
{
  "backup_source": "WHOOP 5 historical export / MG session record",
  "packet_type": "0x52 summary frame",
  "byte_offset": 82,
  "crc_status": "valid",
  "byte_range_observed": [min, max],
  "byte_range_expected": [0, 100],
  "packet_count": N,
  "corruption_detected": false,
  "notes": "..."
}
```

### 0.2 Timestamp Integrity
**Goal**: Confirm the timestamp associated with @82 is accurate and monotonic.

**Tests**:
- [ ] Verify every @82 sample has a corresponding valid Unix timestamp
- [ ] Verify timestamps are monotonically increasing (no backwards jumps)
- [ ] Verify timestamp resolution (seconds, milliseconds, etc.)
- [ ] Cross-check against device clock state and timezone offset
- [ ] Verify no timestamp duplication or gaps larger than expected

**Evidence file**: `references/spo2_timestamp_validation.json`
```json
{
  "sample_count": N,
  "timestamp_range": "[start, end]",
  "timestamp_monotonic": true,
  "max_gap_seconds": 123,
  "timezone_offset": "UTC±X",
  "clock_discontinuities": 0
}
```

### 0.3 Capture Completeness
**Goal**: Confirm @82 data was captured continuously during the sleep window, not sporadically.

**Tests**:
- [ ] Compute coverage: % of sleep window where @82 values exist
- [ ] Identify all gaps and their durations
- [ ] Correlate gaps with known device-off periods (charging, restart, etc.)
- [ ] Confirm no silent zeros or invalid values (e.g., 999 or -1)
- [ ] Flag any night with <80% coverage as incomplete

**Evidence file**: `references/spo2_coverage_report.json`
```json
{
  "nights": [
    {
      "night_id": "2026-09-15",
      "coverage_percent": 87.3,
      "total_samples": 450,
      "expected_samples": 516,
      "gaps": [
        { "start_unix": 123456, "duration_seconds": 120, "reason": "device_off" }
      ],
      "quality_flag": "acceptable"
    }
  ]
}
```

---

## Stage 1: Physiological Plausibility (Baseline Sanity Checks)

Once data integrity is confirmed, check if the values look like oxygen saturation at all.

### 1.1 Range and Distribution
**Goal**: Confirm @82 values are in a physiologically plausible range.

**Tests**:
- [ ] Verify all values are in the range [80, 100]%
- [ ] Compute mean, median, std dev of @82 across all nights
- [ ] Identify outliers (>3σ from mean)
- [ ] Check for bimodal distribution (e.g., two clusters)
- [ ] Confirm distribution makes sense for sleep (normal SpO2 at rest is 95–99%)

**Expected**:
- Mean SpO2 during sleep: ~96–98%
- Minimum SpO2 during sleep: ~90–95% (occasional dips)
- Few values <90% unless sleep apnea is present

**Evidence file**: `references/spo2_distribution.json`
```json
{
  "all_nights": {
    "mean": 97.2,
    "median": 97.5,
    "std_dev": 2.1,
    "min": 82,
    "max": 100,
    "percentile_5": 94.1,
    "percentile_95": 99.8,
    "outliers_detected": 12,
    "plausible_range": true
  },
  "night_level": [
    { "night_id": "2026-09-15", "mean": 96.8, "min": 91, "max": 100 }
  ]
}
```

### 1.2 Temporal Smoothness
**Goal**: Confirm @82 doesn't jump erratically (characteristic of sensor error).

**Tests**:
- [ ] Compute sample-to-sample difference (Δ SpO2)
- [ ] Identify jumps >5% between consecutive samples
- [ ] Count "spikes" (isolated high or low values surrounded by opposite values)
- [ ] Compute autocorrelation (should be high for a real signal)
- [ ] Compare against known artifact patterns

**Expected**:
- Most Δ SpO2 values: ±2%
- Rare jumps >5%
- No random noise > 10%

**Evidence file**: `references/spo2_smoothness.json`
```json
{
  "delta_stats": {
    "mean_abs_delta": 0.8,
    "max_delta": 18,
    "spikes_detected": 3,
    "spike_threshold": 10
  },
  "autocorrelation_lag1": 0.92,
  "autocorrelation_lag10": 0.78
}
```

### 1.3 Sleep State Correlation
**Goal**: Confirm @82 behaves differently during wake vs. sleep.

**Tests**:
- [ ] During sleep: expect SpO2 relatively stable (~96–98%)
- [ ] During wake/movement: expect more variability
- [ ] Cross-check @82 against motion data from `gravitySamples`
- [ ] Verify SpO2 does not change during known motion (motion artifact)
- [ ] Confirm SpO2 dips correlate with REM sleep (known phenomenon)

**Expected**:
- Sleep (deep/light): steady SpO2, ~97%
- REM sleep: occasional dips to 94–96%
- Wake: higher variability, often 95–100%

**Evidence file**: `references/spo2_sleep_correlation.json`
```json
{
  "sleep_stages": {
    "wake": { "mean_spo2": 97.8, "std_dev": 2.3 },
    "light": { "mean_spo2": 96.9, "std_dev": 1.1 },
    "deep": { "mean_spo2": 96.5, "std_dev": 0.9 },
    "rem": { "mean_spo2": 95.8, "std_dev": 1.8 }
  },
  "rem_dip_frequency": 0.34,
  "dip_correlation_with_rem": "moderate"
}
```

---

## Stage 2: Reference Pairing (THE CRITICAL TEST)

This is where the hypothesis succeeds or fails: **Does @82 agree with an independent oximeter?**

### 2.1 Recruitment and Consent
**Goal**: Collect simultaneous captures with an independent reference.

**Setup**:
- [ ] Recruit 5–10 volunteer participants
- [ ] Obtain informed consent for multi-night study
- [ ] Each participant: 3–5 nights minimum
- [ ] Total target: 15–40 reference nights

**Safety boundary**:
- No medical claims
- No diagnosis or treatment
- Purely observational research
- Clear labeling: "experimental signal, not for medical use"

### 2.2 Independent Reference Oximeter
**Goal**: Capture true SpO2 using a validated medical or consumer reference.

**Options** (in order of strength):

| Device | Accuracy | Cost | Pros | Cons |
|--------|----------|------|------|------|
| **Nonin 3150 WristOx2** | ±3% | $300 | Gold standard, wrist-worn, validated | Consumer-grade, not FDA medical |
| **Masimo Rad-97** | ±1–2% | $1–2K | Clinical-grade, very accurate | Expensive, not wrist-worn, bulky |
| **Pulse oximetry smartphone app** (validated model) | ±4–5% | $10–50 | Cheap, always available | Variable accuracy, lighting dependent |
| **Pulse CO-Oximeter** (clinical, e.g., Masimo SET) | ±1–2% | Hospital use | Highest accuracy | Requires hospital/clinical access |

**Minimum recommendation**: Nonin 3150 WristOx2 (or equivalent validated consumer device)
- Worn on opposite wrist from NOOP/WHOOP during night
- Records timestamp, SpO2, pulse rate every second
- Must be validated against medical standard (not optional)

### 2.3 Simultaneous Capture Protocol
**Goal**: Ensure NOOP, WHOOP, and reference oximeter all capture the same time window.

**Protocol**:
1. Participant wears all three devices (NOOP + WHOOP + reference oximeter)
2. Start devices ~30 min before bed
3. Sleep normally
4. All devices remain on until participant wakes
5. Export data from each device at exact-second timestamps
6. Record device start/end times

**Data structure**:
```
night-ref-2026-09-15/
  noop_raw_signals.json          # HR, motion, respiration from NOOP
  whoop_spo2_at82.json           # @82 byte data from WHOOP backup/live
  whoop_reference_spo2.json      # WHOOP's own SpO2 claim (if exported)
  reference_oximeter_spo2.json   # Independent device (Nonin, etc.)
  timestamp_alignment.json       # Clock offset calibration
  manifest.json                  # Device IDs, start/end times, notes
```

### 2.4 Timestamp Alignment
**Goal**: Ensure all three data streams are synchronized to the same clock.

**Tests**:
- [ ] Find known calibration point (e.g., when participant puts on all devices)
- [ ] Compute clock offset between each device and Unix time reference (NTP)
- [ ] Verify clock drift over 8–10 hours is <2 seconds
- [ ] Resample all three signals to identical 1-Hz grid
- [ ] Confirm resampled timestamps match within 1 second

**Evidence file**: `references/spo2_timestamp_alignment.json`
```json
{
  "night_id": "2026-09-15",
  "noop_clock_offset_seconds": 0.3,
  "whoop_clock_offset_seconds": -0.5,
  "reference_oximeter_offset_seconds": 0.1,
  "drift_over_8h_seconds": 1.2,
  "alignment_quality": "good",
  "resampled_to_1hz": true
}
```

### 2.5 Agreement Metrics (THE CRITICAL COMPARISON)
**Goal**: Quantify how well @82 predicts independent SpO2.

**Metrics**:

1. **Mean Absolute Error (MAE)**
   - MAE = mean(|WHOOP@82 - Reference|)
   - Target: <3% (acceptable consumer device)
   - Better: <2%
   - Clinical-grade: <1.5%

2. **Root Mean Squared Error (RMSE)**
   - Penalizes large errors
   - Target: <4%

3. **Correlation (Pearson's r)**
   - How well do they track together?
   - Target: r > 0.85 (strong)
   - Better: r > 0.90

4. **Bland-Altman Bias**
   - Systematic over/under-estimation
   - Target: bias ~0% (no consistent offset)
   - Acceptable: |bias| <2%

5. **Sensitivity/Specificity for Desaturation**
   - Define a clinical threshold: SpO2 <90%
   - Does @82 correctly identify when SpO2 drops?
   - Target: Sensitivity >80%, Specificity >95%

**Evidence file**: `references/spo2_agreement_metrics.json`
```json
{
  "nights": [
    {
      "night_id": "2026-09-15",
      "sample_count": 450,
      "mae": 2.1,
      "rmse": 2.8,
      "correlation": 0.91,
      "bias_percent": 0.3,
      "sensitivity_for_desaturation": 0.87,
      "specificity_for_desaturation": 0.96
    }
  ],
  "aggregate": {
    "mean_mae": 2.3,
    "mean_rmse": 2.9,
    "mean_correlation": 0.89,
    "overall_bias": 0.2,
    "overall_sensitivity": 0.84,
    "overall_specificity": 0.95,
    "verdict": "ACCEPTABLE_FOR_RESEARCH"
  }
}
```

### 2.6 Pass/Fail Criteria
**To move from EXPERIMENTAL_UNVALIDATED to RESEARCH_VALIDATED:**

✅ **MUST PASS**:
- [ ] MAE ≤ 3% across all nights
- [ ] Correlation r ≥ 0.85 across all nights
- [ ] No significant systematic bias (|bias| < 2%)
- [ ] Minimum 10 paired reference nights
- [ ] No catastrophic failures (e.g., night where MAE >10%)

✅ **STRONGLY RECOMMENDED**:
- [ ] Minimum 15–20 paired nights
- [ ] Diversity: age, sex, fitness level, sleep quality
- [ ] Include 3–5 nights with known sleep apnea (if ethically available)
- [ ] Reference device validated against clinical gold standard

---

## Stage 3: Physiological Validity (Clinical Checks)

Once agreement is proven, check if @82 behaves like real physiology.

### 3.1 Apnea/Hypopnea Detection
**Goal**: Does @82 show characteristic SpO2 dips during apnea events?

**Tests**:
- [ ] Recruit 2–3 participants with mild–moderate sleep apnea (AHI 5–30)
- [ ] Compare @82 desaturation events against reference oximeter
- [ ] Measure time-to-recovery from dips
- [ ] Verify dips correlate with cessation of airflow (if respiratory effort available)

**Expected**:
- SpO2 dips should appear after cessation of breathing (5–15 second lag)
- Recovery should take 5–30 seconds
- Number of dip events should match between @82 and reference

### 3.2 REM Sleep Characterization
**Goal**: Do @82 values show REM-specific patterns?

**Tests**:
- [ ] Identify REM periods from motion + HR patterns
- [ ] Compare SpO2 variability in REM vs. deep sleep
- [ ] Measure frequency of micro-arousals and SpO2 fluctuations in REM
- [ ] Verify REM dips are physiological (not noise)

### 3.3 Altitude and Hypoxia Response
**Goal**: Does @82 respond correctly to altitude or known hypoxia?

**Optional advanced test**:
- [ ] Collect data at altitude (6,000+ feet) or in hypoxia chamber
- [ ] Verify @82 decreases as expected
- [ ] Compare descent/ascent responses between @82 and reference

---

## Stage 4: Device Generalization (Robustness)

Once validated on one device, confirm it works across WHOOP model variants.

### 4.1 Model Diversity
**Goal**: Is @82 consistent across different WHOOP hardware revisions?

**Tests**:
- [ ] Test on WHOOP 3.0, 4.0, 5.0, and Strap 2.0 (if available)
- [ ] Verify @82 decoding is identical or well-calibrated across models
- [ ] Account for any firmware differences
- [ ] Confirm backup format is consistent

### 4.2 Firmware Versions
**Goal**: Does @82 encoding change with firmware updates?

**Tests**:
- [ ] Document firmware version for each device
- [ ] Re-run reference pairing across 2–3 firmware versions
- [ ] Verify no significant drift or recalibration

---

## Stage 5: Production Safety (Final Gate)

Before any production use, safety and liability must be addressed.

### 5.1 Clinical Disclaimers
- [ ] Clearly state: "SpO2 is for research only, not medical diagnosis"
- [ ] Do not claim accuracy beyond what evidence supports
- [ ] Do not use in medical decision-making
- [ ] Do not advertise as sleep apnea detector

### 5.2 Regulatory Review
- [ ] Check if SpO2 claims trigger FDA / CE / regulatory scrutiny
- [ ] Consult legal team on liability
- [ ] Confirm no medical device classification issues

### 5.3 User Privacy
- [ ] Confirm reference pairing data is de-identified and consented
- [ ] Store reference data separately from production
- [ ] Never export internal @82 bytes without user consent

---

## Testing Timeline and Resource Plan

### Phase 1: Data Integrity (2–3 weeks)
- Recover and validate WHOOP backup
- Verify CRC, timestamps, coverage
- Output: `spo2_backup_integrity_report.json`

### Phase 2: Plausibility Checks (1 week)
- Analyze distribution, smoothness, sleep correlation
- No field testing needed
- Output: Distribution and smoothness reports

### Phase 3: Reference Pairing (4–8 weeks)
- Recruit volunteers (1–2 weeks)
- Collect 15–20 paired reference nights (2–4 weeks)
- Process and validate data (1–2 weeks)
- Compute agreement metrics
- **Output: `spo2_agreement_metrics.json` (PASS/FAIL gate)**

### Phase 4: Physiological Validity (2–4 weeks, conditional)
- Only if Phase 3 passes
- Recruit apnea cohort and run specialty tests
- Output: Clinical validation report

### Phase 5: Production Safety (1–2 weeks)
- Legal review
- Safety disclaimers
- Output: Safety and liability policy

---

## Current Evidence Status

**Today**: 
```
EXPERIMENTAL_UNVALIDATED

✗ Zero paired reference nights
✗ No independent oximeter agreement
✗ Coverage incomplete (retention gaps known)
✓ Plausible range [80, 100]%
✓ Monotonic timestamps
✓ CRC validated on stored frames
```

**After Phase 1**: 
```
INTEGRITY_VERIFIED

✓ Backup integrity confirmed
✓ Timestamps validated
✓ Coverage documented
✓ No data corruption
```

**After Phase 3** (if metrics pass):
```
RESEARCH_VALIDATED

✓ MAE ≤3% against independent reference
✓ Correlation r ≥0.85
✓ 15+ paired reference nights
✓ No systematic bias
→ Safe for research/evaluation only
→ NOT safe for medical claims
```

**After Phase 5** (if all pass):
```
PRODUCTION_READY

✓ All prior gates passed
✓ Legal review complete
✓ Safety disclaimers in place
✓ Privacy/consent confirmed
→ May be exposed in UI with clear disclaimers
→ Labeled as "experimental"
```

---

## Quick Reference: What Must Happen Before Using @82 in Production

1. **Minimum viable evidence**: 10+ paired reference nights, MAE <3%, r >0.85
2. **Before UI exposure**: Legal review + clear "experimental" labeling
3. **Before medical claims**: FDA/regulatory review + clinical validation
4. **Before replacing WHOOP SpO2**: Outperform WHOOP's own SpO2 on reference data

---

## Next Immediate Action

**Do this first (1–2 weeks)**:

1. Export the WHOOP 5/MG backup containing @82 data
2. Verify packet structure, CRC, timestamp range
3. Compute coverage percentage across all captured nights
4. Create `spo2_backup_integrity_report.json`
5. Identify which nights have >80% continuous coverage
6. Recruit 3–5 volunteers willing to participate in reference pairing

Then proceed to Phase 3 (reference pairing) once recruitment is confirmed.

---

## References

- Nonin 3150 WristOx2: https://www.nonin.com/products/3150-wristox2/
- Bland-Altman method: Bland JM, Altman DG (1986)
- Sleep apnea validation: Berry RB, et al. AASM Manual (3rd edition)
- SpO2 physiology: Levett JM, Pierson DJ (1984)

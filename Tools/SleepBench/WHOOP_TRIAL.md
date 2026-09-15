# WHOOP trial comparison and source audit

Audited baseline: `ad05ec686103e483eea3627d8ab0e4a7e65cf2f5` on
`sleep-engine-personalization`. This report distinguishes source inspection from
measurement. No personal database, WHOOP export, PSG dataset, or Swift toolchain
was available during this audit. Published benchmark numbers below are repository
claims, not newly reproduced results.

## First implementation

`whoop_trial.py` is a standard-library Python companion to SleepBench. It reads
stored NOOP sessions and English WHOOP `sleeps.csv` exports from a ZIP, directory,
or CSV. It does not replay or change a stager. This separation is necessary because
the existing Swift benchmark reader currently differs from the application.

Run from the repository root, keeping inputs and outputs outside the repository:

```sh
python Tools/SleepBench/whoop_trial.py --db /private/snapshot.sqlite --whoop /private/whoop.zip --device COMPUTED_OWNER --stream-device RAW_OWNER --out /private/comparison.json
python -m unittest discover -s Tools/SleepBench -p 'test_whoop_trial.py' -v
```

Use a consistent, standalone database export. Copying just a live SQLite main file
can lose uncheckpointed records. Sidecar-bearing snapshots are rejected rather
than recovered. SQLite is opened read-only and immutable; all device values are
bound parameters. Outputs are created exclusively, never overwritten. No network
requests occur. The caller must keep the snapshot fixed during the run.

The report includes stage totals, boundary differences, efficiency, MAE, signed
bias, median signed error, correlation where defined, stage-share differences,
and coverage strata. Positive errors mean NOOP exceeds/is later than WHOOP.
Light/deep/REM percentages divide by total sleep; awake divides by time in bed.
Machine summaries exclude user-edited rows. Ambiguous overlap matches are withheld;
fragmented nights are not silently merged. Missing stage totals remain null.
The overlap threshold is 50% of the longer interval, a matching heuristic rather
than a validated physiological threshold. Report unmatched counts alongside errors.

Coverage means unique occupied seconds divided by window duration. It is measured
on both the NOOP and WHOOP windows so an incorrectly shortened NOOP window cannot
hide its missing edges. Measured HR, derived HR, their union, PPG-only seconds,
gravity, adjacent gravity pairs, raw RR, raw respiration, and band states are
reported separately. Absent tables give null; existing empty streams give zero
coverage. Neither means physiological zero. RR source counts are included, but
raw RR coverage is explicitly NOT app-filtered feature coverage. High/medium/low
motion strata (80%/40%) are exploratory reporting bins, not accuracy guarantees.

The CSV adapter follows the English field conventions of WhoopExportImporter;
it does not replace the Swift importer or its broader localization support.
Offset-free timestamps without an explicit cycle timezone are rejected. WHOOP
summary totals do not reconstruct an epoch hypnogram. This tool cannot calculate
epoch agreement, first-REM error, or cycle accuracy from those totals.

Validation performed: 12 synthetic Python tests passed, including actual SQLite
write rejection, unchanged input hash, missing vs zero, PPG/measured overlap,
timezone conversion, ambiguous pairs, duplicate exports, stage gaps, edited-row
exclusion, metric denominators and strict finite JSON. No real-night evaluation
has been performed. The sidecar introduces no Swift/Kotlin analytics or schema
change; no platform twin is required for this offline Python report.

## 1. Architecture and functions — verified source

Live acquisition uses `Strand/Collect/Collector.swift`; history uses
`Backfiller.swift`. Parsed frames flow through WhoopProtocol decoding and
`extractHistoricalStreams`, then `WhoopStore.insert`. History persistence occurs
before acknowledgement. `StreamStore.swift` stores HR, RR, gravity, respiration,
band state, PPG estimates, and raw PPG in separate tables.

`Reads.swift.hrSamples` coalesces measured HR with derived HR using measured-first
timestamp precedence. `rrIntervals` selects permitted RR sources and excludes
suspect timestamps. `IntelligenceEngine.swift` reads inputs and threads experiment
settings into `AnalyticsEngine.analyzeDay`.

`SleepStager.detectSleep` owns window detection, sparse/HR-only handling and
several guards. The normal path calls V1 or `SleepStagerV2.stageSession` for stage
assignment, then applies a band-state wake veto. V2 is default-on in
`PuffinExperiment`; some pure function parameters default false, so direct calls
must explicitly select the intended recipe. The HR-only path directly calls V2.

`AnalyticsEngine` optionally applies `WakeMotionRefinement.refine` to detected
sessions. This additional motion/step refinement is DEFAULT OFF. It is not the
same as V2's always-present motion-quiescence cardiac clamp. IntelligenceEngine
persists sessions and their motion/band-state arrays. Manual restaging in
`Repository.swift` is another caller and must be tested independently.

`SleepModel`/`SleepView` decode and group persisted sessions for display.
`HealthKitBridge.writeBack` reads stored sessions; `writeSleep` delegates to the
sleep writeback path. Its documented aggregate-only fallback uses unspecified
sleep rather than inventing timed stages. Exported NOOP stages must never return
through Apple Health as an independent validation reference.

## 2. Available signals and v26 — verified implementation, not hardware completeness

The decoded WHOOP 5 paths can provide HR, RR intervals, gravity, movement counters,
respiration-related samples and coarse sleep states. Availability is record- and
firmware-dependent; a sensor's existence does not guarantee a usable overnight
stream. The decoded state mapping is 0 wake, 1 still, 2 asleep, 3 up. These are not
light/deep/REM labels and their physiological accuracy is not established here.

`HistoricalStreams` collects v26 optical waveform records; `PpgHr` processes them
at 24 samples/second using windowed autocorrelation and a quality threshold. The
implemented output is derived HR, not measured motion or beat-to-beat RMSSD.
Other record types may overlap v26, so v26 presence alone does not prove that an
entire time interval lacks motion/RR. Measure each stream separately. Raw waveform
storage exists, with a retention cap: absence in an old database may reflect
retention, not original acquisition failure.

The HR read maps measured and derived values into the same HRSample shape. V2
therefore does not retain their origin or the PPG estimator confidence. HR
variation after this merge is not automatically equivalent across both sources.

## 3. Missing-data audit — verified

In `SleepStagerV2.features`, an HR-covered epoch without gravity has no jerk
pairs. `jerkMax` becomes zero, denominator is at least one, and movement fraction
becomes zero. `motionQuiescent` returns true, suppressing positive cardiac wake
evidence. Confidence that this code path exists: 0.99. Whether it explains a
particular wearer's errors remains unknown until paired data are evaluated.

Further findings:

* Missing HR mean/variability become optional values and z-score to zero.
* Missing 11-minute HR flatness gets percentile 0.5. The deep gate still applies
  `5 * (0.5 - 0.25) = 1.25` log-score penalty. This is a prior penalty, not removal
  of the unavailable feature.
* V2 accepts raw respiration for API compatibility but does not consume it.
  Respiratory regularity is derived from RR; insufficient RR produces nil and
  removes that term. V2's HR standard deviation is not beat-to-beat RMSSD.
* HR variability windows can be accepted with only two observed seconds. Counts,
  temporal spread and gap lengths are not retained as feature quality.
* Gravity timestamps are discarded before consecutive values are differenced;
  values separated by missing seconds are treated as neighbouring observations.
* Epochs with neither HR nor gravity are skipped, even if RR exists. The returned
  segments fill gaps and edges; completely empty coverage returns light sleep.
* Onset run counting and HMM transitions operate on the retained epoch sequence.
  Removed time is not represented as an explicit unknown state.

No algorithmic correction was made during this audit.

## 4. Tests and benchmark weaknesses

The inspected V2 tests cover ordering, tiling, labels, degenerate light fallback,
cycle priors, REM guard, onset runs, Viterbi, flag threading and a golden night.
WakeMotionRefinement has its own density and behaviour tests. SleepBench has
calibration tests; SleepPSG has scoring, dataset/ablation and recipe-port tests.
The test inventory was inspected; the Swift suites were not executed here.

The initial audit found a high-priority mismatch: SleepBench read only `hrSample`,
while the app reads measured HR plus `ppgHrSample` fallback. Its R-R query also
omitted the current source/suspect filters and differed in ordering. The reader now
mirrors those store policies: measured HR wins per second, WHOOP 5 is pinned to one
verified R-R transport, suspect timestamps and the duplicate SpO2 IBI channel are
excluded, and emission ordering is preserved. Legacy snapshots are feature-detected;
missing provenance columns remain missing and are never guessed into a modern source.

All reader values are now bound parameters and terminal `sqlite3_step` failures are
reported. These changes make replay inputs match the current app policy; they do not
change a stager or establish physiological accuracy.

SleepPSG's baseline calls the shipped stager, while variants use RecipePort. Its
synthetic equivalence suite is valuable and must pass after any recipe edit.
The README reports 31 subjects / 26,773 scored epochs and explicitly says session
detection is not tested. These historical values have not been reproduced here.

## 5. Ranked changes and acceptance tests

1. Freeze source, flags, input hashes and reference provenance; keep replay HR/RR
   parity tests aligned with the store as either read policy evolves. Confidence 0.99.
2. Add feature availability, sample counts, maximum gaps and derivation origin.
   Keep diagnostic extraction observational before changing labels. Confidence 0.98.
3. As one controlled ablation, make absent motion unknown: optional movement/jerk,
   exclude missing values from normalization, and require adequate observed pairs
   for quiescence. Test no samples, one sample, sparse disconnected samples, dense
   stillness, movement and mixed nights. Mirror Kotlin and RecipePort. Confidence
   0.97 for correcting semantics; improvement in classification is unmeasured.
4. Separately test missing-flatness gating and all-channel gaps. Preserve a full
   epoch grid with an evidence mask; represent unscorable time in summaries and
   exports. Tests must cover non-grid boundaries, gaps through onset and all-empty
   input. Existing light-fallback tests would need intentional revision. 0.96.
5. Add model probabilities and calibration evaluation. Then limited personalized
   baselines. Consider HSMM only after those foundations. 0.90.
6. Smart wake and an explainable score are later product experiments. 0.90 for
   postponing; no claim of demonstrated clinical benefit.

Required Swift gates: `swift test` in Packages/StrandAnalytics, WhoopStore,
StrandImport, Tools/SleepBench and Tools/SleepPSG; paired baseline/candidate
SleepBench and full SleepPSG runs using frozen references; app build/tests if UI
or app callers change; Kotlin parity for shared analytics. Record per-stage
recall/F1, kappa, stage-minute/share errors, boundaries, abstention coverage and
subject/night-level uncertainty intervals. Do not accept an improvement based on
one aggregate statistic. Predeclare regression margins before seeing results.

## 6. Trial calibration, personalization and PSG

Collect paired exports through the trial, plus brief independently recorded bed,
lights-out, final wake and unusual-night notes. Preserve app/firmware versions and
flags. Verify both pipelines actually retain the same nights; do not assume
concurrent collection is lossless. Do not publish personal files.

Use WHOOP as a noisy external comparator. Night totals support aggregate errors,
not epoch accuracy or true cycle boundaries. Separate acquisition, window
detection, staging and presentation errors. Include unmatched and low-coverage
nights, otherwise selection can make accuracy appear better.

Begin personalization with robust signal baselines and sensor noise estimates.
Shrink estimates toward population values using effective clean-night counts,
cap adaptation speed and evaluate on later untouched nights. Do not random-split
epochs. Stage proportions inferred by NOOP must not become self-certified truth.
Sleep timing observations are not direct measurements of biological circadian
phase. School schedules can constrain observed sleep independently of preference.
Recommendation confidence: 0.95.

PSG remains the strongest stage reference. The public sleep-accel data contain
Apple Watch motion/HR and PSG labels, not WHOOP RR. They test transfer across
hardware but cannot validate the RR respiratory feature or prove personalized
teenage accuracy. The primary dataset description is
https://physionet.org/content/sleep-accel/1.0.0/ .
Repeated model selection against the same PSG cohort makes it development data,
even when coefficients are hand-chosen. Reserve untouched subjects/datasets and
use subject-grouped or nested evaluation. Add an appropriate RR+PSG dataset before
claiming that RR-related changes are scientifically validated. Confidence 0.98.

## 7. Probabilities, smart wake and scoring

Retain emission scores and compute forward-backward state marginals for the
offline model. Viterbi provides a best path, not per-epoch confidence. A softmax of
emissions alone omits sequence information. Even normalized marginals are model
probabilities, not calibrated correctness: evaluate log loss, Brier score and
reliability on held-out labels. Store stage distribution, measured/derived/missing
feature status, coverage, entropy, model version and postprocessing decisions.
Keep sensor quality separate from model certainty. Confidence 0.96.

Smart wake needs a SEPARATE causal inference path. Current V2 uses future HR,
full-night normalization, session-end timing and two-pass decoding. It cannot
simply run unchanged in real time. Use past-only features, bounded latency,
deadline fallback and fail-safe local alarm behaviour. Preserve required sleep
opportunity; stage estimates alone do not establish which wake time improves
alertness. Evaluate outcomes independently of the model's own stage labels.
Confidence 0.98 for the causality requirement; effectiveness remains a hypothesis.

The current AnalyticsEngine already has an explainable composite framework and
age-related need logic. Extend that rather than introducing a competing score.
Prefer duration, continuity and regularity; keep uncertain architecture secondary.
Display data quality beside the score rather than treating sensor failure as bad
sleep. Label any unvalidated numeric combination a heuristic. Personal resting
physiology and circadian alignment are estimates, not recovery ground truth.
Confidence 0.93 for this design direction.

## 8. Scientific corrections to the brief and repository comments

* A human-authored stage edit is not PSG. A diary can anchor wake boundaries but
  cannot establish deep or REM. Rank references by how their labels were obtained.
* Band state is already used by the full pipeline. Agreement with it after the
  veto is not independent validation; isolate that input in ablations.
* No RR in sleep-accel does NOT make its accuracy a mathematical lower bound on
  performance with RR. Another feature can hurt, particularly if noisy.
* Hand-selected parameters can overfit through repeated benchmark inspection.
  The README's claim that no fitting means no split is needed is too strong.
* Stillness does not prove sleep; quiet wake remains possible. Suppressing wake
  evidence needs validation, not an assertion that raised HR while still is sleep.
* A low-rate waveform may contain more information than this HR estimator uses,
  but reliable beat-level HRV is not established by the current v26 path. Neither
  promise recovery from it nor declare all future extraction impossible.
* Cycles are uncertain inferred patterns, not a fixed 90-minute clock. Strong
  cycle priors can create the patterns later claimed as measurements.
* A more convincing hypnogram or closer WHOOP totals do not prove better sleep
  staging. Superiority to WHOOP would require suitable independent ground truth.

Overall audit confidence: 0.94 for identified source paths and missing-data
semantics. Personalized accuracy, real-night effect sizes, calibrated confidence
and smart-wake benefit remain unknown.

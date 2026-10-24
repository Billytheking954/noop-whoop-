# NOOP V2 × Aura — Phase 1 architecture and personal-accuracy decision

**Decision date:** 24 October 2026  
**Production boundary:** documentation only; `main` was not changed.  
**Validated V2 head inspected:** `f701c2e72f86055291826d1010ec5d57f6d15504`  
**Aura reference inspected:** `v12.0.0-aura.1209`, commit/tree `004584b30310f516a060579141038d0e0f1790ba`  
**Common merge base:** `7acce06c3d22cb5dfe959f2c4a43902471d21332`

## 1. Executive verdict

Use **architecture C: a controlled hybrid**.

Port Aura's iPhone shell, navigation treatment, typography, colour tokens, cards, charts and selected screen composition onto V2, but keep V2's repositories, view-state owners, BLE manager, persistence, import/backup paths, HealthKit safeguards and physiological engines. Aura views must receive explicit adapter/view-model inputs; they must not directly recreate data access, infer missing values or import Aura's experimental business logic.

Do **not** merge the Aura tag. The previous assumption that Aura 1209 was an ancestor of V2 is false. GitHub's exact comparison reports the histories as **diverged**: V2 is 295 commits ahead and 384 behind Aura, with merge base `7acce06…`. A tag merge would combine hundreds of unrelated changes and reverse or conflict with reliability work.

The validated V2 IPA remains only the pre-Aura, hardware-unverified candidate from `f701c2e…`. This Phase 1 document does not make that artifact contain Aura.

## 2. Verified repository state

- PR [#52](https://github.com/Billytheking954/noop-whoop-/pull/52) was open and draft at inspection; its head remained `f701c2e…`.
- The unsigned-iPhone workflow [40082678490](https://github.com/Billytheking954/noop-whoop-/actions/runs/40082678490) completed successfully at the exact head. Its archive, IPA verification and upload steps passed.
- The exact-head simulator build/test workflow also completed successfully. Nineteen check runs were present and completed successfully at inspection.
- PR #49 commit `852449e…` is an ancestor of the V2 head (head is 8 commits ahead, 0 behind).
- PR #51 commit `8c5ac98…` is an ancestor of the V2 head (head is 135 commits ahead, 0 behind).
- The Aura release source is `004584b…`, not an ancestor of the V2 head.
- V2 and Aura both carry the PolyForm Noncommercial 1.0.0 licence and required notice `Copyright 2026 NoopApp`. Ported source and distributions must retain the licence, required notice, NOTICE and third-party attributions. Commercial use is not granted.

## 3. Council decisions

| Perspective | Preferred implementation | Evidence | Main objection/risk | Decision | Confidence |
|---|---|---|---|---|---|
| Senior iOS architect | Adapter-driven hybrid on V2 | Aura has a separate, large `StrandiOS/NoopUI` shell; V2 has substantially changed `RootTabView`, models and services | Whole-file copying would overwrite V2 lifecycle and routing work | Port visual modules and compose them with V2-owned state | High |
| UI/UX designer | Faithfully reuse Aura tokens and canonical shell, with real V2 data and accessible fallbacks | Aura includes `NoopDesign`, `NoopShell`, `NoopNavigation`, Act screens and Aura design primitives | Exact screenshots can tempt fake placeholders or fixed layouts | Reproduce style and information architecture; reject prototype/fake content | High |
| Bluetooth/wearable engineer | Keep V2 BLE and device-state logic | V2 contains PR #49/#51 safeguards and later pairing/error/battery work; Aura's BLE file is not demonstrably better | Aura device UI could reintroduce stale “Searching” and ambiguous source state | Style V2 device flows; never replace `BLEManager` | High |
| Physiological data scientist | Overnight RMSSD for readiness, distinct trusted SDNN only for HealthKit; scores labelled estimates | V2 implements cleaned RR/RMSSD and explicitly labels recovery/sleep approximation; Apple HealthKit requires SDNN | Composite recovery weights and sleep stages are not clinically validated | Keep measurement pipeline, harden definitions and uncertainty; shadow-test algorithm changes | High |
| Statistics/personalisation | Individual baseline with log-RMSSD, recent weighting and source isolation | Export supplies 37 core nightly aggregates; V2 already separates imported and own nights | 43 days is short and WHOOP-derived, not independent truth | Use export to seed, not permanently anchor; 28-day operational baseline + 7-day trend | Medium-high |
| Database/reliability | Preserve V2 schema/migrations, provenance and idempotent natural keys | V2 importer and stores use source/device namespaces and upserts; PR #49 protects backup/WAL paths | Aura adds optional routine columns and large features with migration risk | Add only additive, rollback-safe adapter/provenance changes in Phase 2 | High |
| QA/release | Incremental screen slices with exact-head CI and physical-device gates | Current green CI does not prove real WHOOP or SideStore behaviour | A big-bang UI port would be hard to bisect | Land vertical slices; no release claim until physical acceptance passes | High |

### Resolved disagreements

- **Visual fidelity vs reliability:** fidelity wins only inside the presentation layer. V2 owns data, BLE, storage and lifecycle.
- **Reuse Aura's full shell vs adapt V2 screens:** reuse Aura's design primitives and navigation treatment, but bind through V2 adapters. Do not copy Aura services or prototype policy.
- **Change scoring now vs preserve behaviour:** Phase 2 may add correctness fixes and shadow models, but must not silently replace stable scores without overlap validation.
- **Use all 43 days forever vs a shorter rolling baseline:** use valid export nights for cold-start, then age them out. Imported vendor values must not permanently pin the baseline.

## 4. Component-level UI integration plan

### 4.1 Port as visual infrastructure

Port from Aura commit `004584b…`:

- `Packages/StrandDesign/Sources/StrandDesign/Aura/NoopPalette.swift`
- `NoopSpecTokens.swift`
- `NoopSpecType.swift`
- `NoopSpecMotion.swift`
- `NoopSpecPrimitives.swift`
- `NoopChargeGauge.swift`
- `StrandiOS/NoopUI/NoopDesign.swift`
- `StrandiOS/NoopUI/NoopHistoryPlot.swift`
- the visual/navigation parts of `NoopNavigation.swift` and `NoopShell.swift`

Retain dynamic type, Reduce Motion, contrast and VoiceOver behaviour. Add snapshot coverage for compact iPhones and accessibility sizes before replacing the root shell.

### 4.2 Adapt, do not copy blindly

| Surface | Aura source | V2 source/state to preserve | Integration decision |
|---|---|---|---|
| Root navigation | `StrandiOS/NoopUI/NoopShell.swift`, `NoopNavigation.swift`, Aura `RootTabView.swift` | V2 `StrandiOS/App/RootTabView.swift`, `NavRouter`, quick actions and lifecycle | Rebuild Aura-style bottom navigation around V2 routes; preserve V2 deep links, reset and quick-action handlers |
| Today/Charge | `Acts/NoopAct2Day.swift`, `NoopTodayCards.swift`, `NoopChargeGauge` | `Repository.days`, `chargeBaselines`, `TodayView`, provenance/confidence | Use Aura composition with an `AuraTodayAdapter`; no prototype values |
| Rest/Sleep | `Acts/NoopAct1Night.swift` | V2 `SleepView`, `SleepModel`, edit/undo, computed/imported source labels | Port layout and charts; retain V2 editing, source isolation and “estimated stage” labelling |
| Fitness/workouts | `Fitness/NoopFitnessHome.swift`, `NoopFitnessDetails.swift`, session parts | V2 workout store, live session runner, strain and route handling | Port home/detail presentation first; defer routines, exercise media and auto-learning |
| Trends/history | `Acts/NoopAct4Trends.swift`, `AuraHistoryPresentation.swift`, `NoopHistoryPlot.swift` | V2 `TrendsView`, `DatedChartSeries`, source/provenance resolution | Adopt Aura history presentation after deterministic range/missing-data tests |
| Health/stress | Aura day/record screens | V2 `HealthView`, `StressView`, live HR and stress engines | Restyle and adapt; no new physiological claims |
| You/settings | `Acts/NoopAct5You.swift` | V2 settings stores, data sources, backup, diagnostics | Port in subsections; keep every V2 safety control and status surface |
| Devices/pairing | Aura device styling | V2 `DevicesView`, `AddDeviceWizard`, `BLEManager`, source-aware battery formatting | **Style only.** V2 scanning, connection, errors, battery source and removal logic remain authoritative |

### 4.3 Reject for Phase 2

- `NoopContentPolicy.allowsPrototypeContent` paths or any fake/sample data.
- A direct replacement of V2 `RootTabView`, `AppModel`, `Repository`, `BLEManager`, `Database`, `DataBackup` or `HealthKitBridge`.
- Aura's automatic workout-learning model as a default production feature.
- Exercise animation downloads and their external media/licensing surface.
- Large routine-editor/database changes unless separately reviewed and migrated.
- Experimental SpO2, respiratory or sleep-stage diagnostics as production scoring inputs.

## 5. Underlying feature decisions

| Area | Decision | Reason |
|---|---|---|
| WHOOP pairing/connection | **KEEP V2** | V2 includes audited reconnect, scan-error, pairing and source-aware battery work |
| Live HR | **KEEP V2** | No demonstrated Aura reliability advantage |
| Historical offload | **KEEP V2** | Preserve V2 continuation, cursor, timestamp and rejection safeguards |
| Battery/background | **KEEP V2** | V2 contains later source and background correctness work |
| Offline database | **KEEP V2** | Preserve schema, migrations, source namespaces and integrity tests |
| Backup/restore/export | **KEEP V2** | Preserve PR #49 WAL/rollback/integrity hardening |
| HealthKit | **HYBRID** | Keep V2 safety/identity path; adopt Aura's trusted-SDNN export gate after tests |
| HRV | **HYBRID** | Keep V2 RR cleaning/RMSSD; use Aura's additional SDNN trust helper only for true SDNN destinations |
| Resting HR | **KEEP + SHADOW** | Keep shipped primary-session floor until a larger overlap validates the existing primary-session mean shadow |
| Recovery/Charge | **KEEP + HARDEN** | V2 and Aura core scorer are identical; improve labels, confidence and log-RMSSD shadow rather than silently reweight |
| Strain/Effort | **KEEP V2** | V2 has later timestamp/gap and denominator safeguards; Aura's presentation wrapper does not justify replacing the engine |
| Sleep detection/staging | **KEEP V2** | V2 contains later reliability fixes; stages remain estimates without PSG validation |
| Activity detection | **DEFER** | Aura's learning feature is useful but raises false-positive and migration risks |
| Workout presentation | **ADOPT AURA UI** | Clear functional advantage without replacing V2 records or scoring |
| Routines/exercise library | **DEFER** | Valuable but not necessary for the first daily-driver release |
| Trends/charts | **HYBRID** | Adopt Aura charts/history presentation using V2-resolved series and provenance |

## 6. Physiological algorithm decisions

| Metric | Existing V2 | Aura | Evidence assessment | Council decision |
|---|---|---|---|---|
| HRV | Cleaned RR; RMSSD and SDNN; 20-beat minimum; coverage and duplicate gates | Same core plus trusted-SDNN export helper | RMSSD and SDNN are distinct; overnight standardisation improves comparability; PPG/RR quality still matters | Use **overnight RMSSD** for NOOP readiness, log-transform for personal deviation; use SDNN only when actually computed and trusted |
| Resting HR | Longest sleep session; shipped daily value uses a five-minute floor; primary-session mean exists as shadow | Same | The code's own five-night evidence is too small to switch confidently | Keep current output for now; collect mean/median/floor shadow values and switch only after overlap and independent-reference testing |
| Recovery/Charge | Weighted baseline-normalised logistic heuristic | Identical | No universal validated weighting or independent ground truth in the export | Keep transparent heuristic for compatibility, label it **estimate**, show drivers/confidence, develop log-RMSSD model in shadow |
| Strain/Effort | Edwards/Banister TRIMP with personal HRR, gap-capped time integration and NOOP 0–100 log mapping | Older/divergent variant plus cardio-load presentation | HR-derived load is defensible; the 0–100 compression is product-specific | Keep Edwards default and V2 gap handling; label **NOOP Effort**, not WHOOP Strain |
| Sleep | Motion/HR/RR/respiratory heuristic with explicit approximate-stage warning | Related but divergent algorithm/diagnostics | Wrist staging cannot be treated as PSG; duration is more defensible than stage classification | Prioritise sleep window/duration/efficiency; label stages estimated and expose confidence/source |
| Personal baselines | EWMA-style mean/absolute-deviation, 21-day import-seed window, 4-night provisional and 14-night trusted thresholds | Core configuration substantially shared | 43 days supports a provisional personal baseline, not seasonal or clinical inference | Phase 2 should backtest a **28-valid-night** baseline with 14-day half-life; display a 7-day lnRMSSD trend; imported values seed only until 14 own nights |

### 6.1 HRV definition

- Recovery uses **RMSSD**, not SDNN. Compute it from consecutive, cleaned normal-to-normal intervals inside the accepted primary overnight session.
- Reject outputs when RR coverage, duplicate/cross-second delivery or cleaning loss makes the result unreliable; do not interpolate a missing night into existence.
- Use `ln(RMSSD)` for baseline deviation and trends. Keep the raw millisecond value for display.
- Daytime spot readings are separate observations and must not silently replace the nightly value.
- Apple HealthKit's HRV quantity is explicitly SDNN. Never write RMSSD into that type. Aura's `trustedSdnnForHealthKit`-style gate is therefore a narrowly justified adoption.
- Four valid nights may produce a visibly provisional baseline; fourteen valid nights is the minimum “trusted” operational threshold already encoded in V2. This is a product-confidence rule, not a clinical threshold.

### 6.2 Resting HR

For future validation, compare three predefined candidates over the longest main sleep session:

1. current five-minute floor;
2. arithmetic mean of valid samples;
3. robust median or trimmed mean after excluding non-wear, motion-heavy and edge periods.

Do not tune against the same nights used for evaluation. Use a development/holdout split and report bias, MAE, agreement and missingness. WHOOP RHR is a useful comparator but not independent ground truth; a chest-strap/ECG reference is stronger.

### 6.3 Recovery/Charge

Keep the current model during the UI port to avoid confounding UI and physiology changes. Required changes:

- rename/describe it as a **NOOP Charge estimate**, never a WHOOP-equivalent or clinical recovery measure;
- display inputs, source, baseline maturity and missing-term confidence;
- refuse a score when the HRV baseline is unusable;
- do not backfill missing inputs;
- run a shadow model using lnRMSSD and the same source-isolated baseline;
- do not optimise weights to maximise agreement with WHOOP recovery alone.

A future weight change requires an independent target such as standardised morning performance, repeated subjective readiness or external reference measurements.

### 6.4 Strain/Effort

Retain V2's timestamp-aware duration integration and two-minute gap cap. Use observed HRmax only after adequate high-quality coverage; otherwise use an age estimate and label the source. Never count a data gap as exercise. Preserve the term **NOOP Effort** because the logarithmic 0–100 mapping is not WHOOP's proprietary 0–21 model.

Do not add an acute:chronic workload ratio as an injury-risk score; the literature identifies substantial methodological problems. If a 7-day/28-day load comparison is shown, present the two loads separately with context rather than a prescriptive “safe zone”.

### 6.5 Sleep

- Treat onset, wake, total sleep time and efficiency as estimated measurements with source and coverage.
- Sleep stages are model estimates, not clinical measurements.
- Imported WHOOP stage totals are WHOOP-derived aggregates. They can test import/display plumbing but cannot validate NOOP's per-epoch stager because the export has no raw epoch labels or PSG.
- A main-sleep/nap distinction must be preserved; naps must not replace the primary night for RHR or recovery.

## 7. WHOOP export assessment

The private export was inspected locally and was not uploaded to GitHub.

### Present structure

- `physiological_cycles.csv`: 43 cycle rows; 37 contain the core HRV, RHR, recovery and sleep fields.
- `sleeps.csv`: 38 rows: 37 main sleeps and 1 nap.
- `workouts.csv`: 38 unique workout starts.
- `journal_entries.csv`: 856 responses across 35 cycles.
- All supplied timezone fields are `UTC+01:00`.
- Cycle and workout start keys inspected were unique.
- The export contains daily/episode aggregates, not raw beat-to-beat RR, raw PPG, motion or per-epoch sleep-stage observations.

### What it can improve

- Seed a provisional personal HRV/RHR/respiratory baseline immediately.
- Validate parser columns, units, wake-day mapping, nap exclusion, idempotent re-import and timezone handling.
- Provide daily outcome-level comparisons between WHOOP-derived aggregates and overlapping future NOOP results.
- Initialise charts and trends without inventing history.
- Provide activity names, HR-zone percentages and daily/workout summaries as imported reference data.

### What it cannot prove

- It cannot validate NOOP's RR cleaning, RMSSD calculation, live HR, sleep window detector or sleep staging because raw sensor observations are absent.
- It cannot validate DST handling: the file ends before the relevant UK autumn transition and uses one fixed offset.
- WHOOP recovery, strain and stages are proprietary derived values, not independent physiological ground truth.
- It cannot validate WHOOP 5/MG BLE pairing, historical offload or SideStore installation.
- Forty-three days cannot establish seasonal norms or determine clinically meaningful thresholds.

### Import correctness issue found

`WhoopImporter.swift` maps WHOOP's absolute skin temperature into `DailyMetric.skinTempDevC`, despite the inline note acknowledging that the export supplies absolute °C rather than deviation. Those are different quantities. Phase 2 must store it as absolute temperature/provenance (or omit it from deviation scoring) and add a migration/repair test. Imported absolute temperature must never be interpreted as a deviation in Charge.

### Baseline use

Use the latest 28 valid imported nights for the initial operational baseline, with recent weighting equivalent to roughly a 14-day half-life. Use the 7-day lnRMSSD mean/CV as a trend display, not as the baseline itself. As soon as 14 valid NOOP-owned nights exist, imported WHOOP nights should stop contributing; V2's `ChargeBaselines` already has the correct source-handoff pattern, though its current fixed window is 21 days and should be backtested before changing to 28.

## 8. Phase 2 engineering specification

### P0 — correctness and safe integration

1. Create an implementation branch from exact V2 head `f701c2e…`; never merge Aura tag or `main`.
2. Vendor/port the Aura design primitives and required assets with licence/NOTICE preserved.
3. Add typed presentation adapters:
   - `AuraTodayAdapter`
   - `AuraRestAdapter`
   - `AuraFitnessAdapter`
   - `AuraTrendsAdapter`
   - `AuraDeviceAdapter`
   Each must expose explicit loading, unavailable, stale and error states.
4. Add Aura-style shell/navigation around V2 routes while preserving deep links, quick actions, reset flow, sheets and accessibility.
5. Keep `BLEManager`, repositories, stores, migrations, backup, HealthKit identity and score engines unchanged during the first UI slice.
6. Rebuild Devices/Pairing visually using V2 state and actions. Preserve Bluetooth-off, scan-error, reconnect, battery-source and fractional-battery fixes.
7. Correct the absolute-skin-temperature import semantic and add repair/backfill behaviour that cannot feed absolute values into deviation scoring.
8. Ensure WHOOP imported rows, NOOP-computed rows, Apple Health and live strap rows retain separate source identity and deterministic precedence.
9. Add compile/tests after each vertical slice; never land one unreviewable whole UI dump.

### P1 — daily-driver completeness and accuracy hardening

1. Port Today/Charge, Rest/Sleep, Fitness/workout detail, Trends and You/settings in that order.
2. Port `AuraHistoryPresentation` and history charts with deterministic missing-data/range tests.
3. Adopt trusted SDNN export to HealthKit; add tests proving RMSSD is never written as SDNN.
4. Add baseline metadata: source composition, valid-night count, window, last update and provisional/trusted/stale status.
5. Implement the 28-night/log-RMSSD candidate behind a shadow/feature flag; compare it against the current model before switching.
6. Record RHR mean/median/current-floor shadows with coverage; do not change the headline until acceptance criteria pass.
7. Add recovery confidence based on available required inputs and baseline maturity. Confidence must not alter the score secretly.
8. Add an import preview, explicit confirmation, idempotence report and rollback-safe transaction for the WHOOP export.
9. Keep imported proprietary scores viewable as reference series but visually distinct from NOOP estimates.

### P2 — safely deferrable

- Aura routine editor, exercise library and downloadable animations.
- Automatic activity-learning/classification.
- Coach/prototype flows not already backed by verified V2 data.
- New SpO2/respiratory scoring.
- Any recovery-weight optimisation or ML model.
- Cosmetic parity work that harms dynamic type, contrast, VoiceOver or battery use.

## 9. Data architecture and migration

- Continue using device/source namespaces and natural-key upserts.
- Add an import ledger containing: source kind, file digest, parser version, import timestamp, timezone policy and counts — never raw personal values in logs.
- Every imported aggregate must retain `source=whoop_export`, algorithm/definition where known, and whether it is raw, vendor-derived or NOOP-computed.
- Use additive migrations only. Wrap import plus ledger update in one transaction.
- Re-importing the same digest must be idempotent. A changed parser version may run an explicit repair migration.
- Do not commit exports, fixtures derived from personal rows, screenshots containing health history or CI logs with values.
- Backup/restore must continue to include SQLite WAL state and provenance tables, with rollback on verification failure.

## 10. Validation and release gates

### Automated

- Swift package, Python, source-hygiene and localisation workflows pass at the exact implementation head.
- iPhone simulator build and unit tests pass.
- Deterministic tests cover:
  - Aura adapters for loading/missing/stale/error states;
  - navigation/deep-link parity;
  - Bluetooth-off and scan-error states;
  - battery formatting and provenance;
  - DST/local-day boundaries;
  - WHOOP import units, nap handling, idempotence, duplicate natural keys and rollback;
  - absolute temperature vs deviation;
  - RMSSD/SDNN separation and HealthKit type correctness;
  - missing HR gaps do not create strain;
  - imported/own baseline handoff;
  - backup/restore with WAL and new provenance.
- Snapshot/accessibility review on small and large iPhone layouts, light/dark mode, increased contrast, Reduce Motion and large dynamic type.
- No prototype/fake content code path is reachable in release.

### Physical acceptance

At least one real iPhone and the intended WHOOP device must pass:

1. fresh SideStore re-sign and install;
2. HealthKit entitlement/capability check after re-signing;
3. Bluetooth off/on, first pair, reconnect after relaunch and device restart;
4. live HR continuity;
5. historical offload continuation, disconnect/reconnect and duplicate prevention;
6. overnight wear, next-day sleep/HRV/RHR appearance and source labels;
7. battery display and stale-state behaviour;
8. import/re-import of the private export without duplication;
9. backup, destructive test change and verified restore;
10. 24–72 hour observation for crashes, background behaviour, battery cost and database growth.

### Release truthfulness

The Phase 3 IPA may be called:

- **structurally verified** only after package, Mach-O, bundle, provenance and signature-state checks;
- **re-signable** only after a compatible unsigned/ad-hoc artifact is confirmed;
- **hardware-tested** only after the physical gates above;
- **daily-driver candidate** only after multi-day observation.

It must not be called clinically validated, WHOOP-equivalent or proven reliable across WHOOP 5/MG unless those exact claims have evidence.

## 11. Scientific and technical evidence

- Task Force of the ESC/NASPE, *Heart rate variability: standards of measurement, physiological interpretation, and clinical use* (1996): RMSSD and SDNN definitions and recording-duration cautions. https://academic.oup.com/eurheartj/article-pdf/17/3/354/1312587/17-3-354.pdf
- Plews et al., training adaptation and HRV review: supports individualised, repeated lnRMSSD interpretation rather than single-day universal cut-offs. https://pubmed.ncbi.nlm.nih.gov/23852425/
- Plews et al., weekly averaged lnRMSSD in endurance athletes: supports a 7-day trend as a noise-reduced display, not a clinical baseline. https://pubmed.ncbi.nlm.nih.gov/24700160/
- Apple HealthKit documentation: `heartRateVariabilitySDNN` is specifically SDNN, so RMSSD must not be written under that identifier. https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn
- Dial et al. (2025), nocturnal RHR/HRV wearable validation against ECG: supports using nocturnal metrics while showing device-specific error remains. https://pubmed.ncbi.nlm.nih.gov/40834291/
- Robbins et al. (2024), consumer wearable sleep validation against PSG: supports treating duration as more dependable than stage labels and keeping stage estimates qualified. https://pubmed.ncbi.nlm.nih.gov/39460013/
- Impellizzeri et al. (2020), limitations of acute:chronic workload ratios: supports avoiding a prescriptive “safe ratio”. https://pubmed.ncbi.nlm.nih.gov/32125672/

## 12. Phase 1 completion state

**Completed:** live PR/head/CI verification; exact source-tree comparison; ancestry correction; key UI/algorithm/BLE/store/import inspection; private export schema/completeness review; licence review; Council decisions; Phase 2 task order and acceptance gates.

**Blocked/unverified:** real-device WHOOP 5/MG behaviour; SideStore's final entitlements; independent physiological accuracy; NOOP-vs-WHOOP overlap because the export has no overlapping NOOP raw/results dataset; PSG/ECG validation; physical-device UI screenshots.

**Next engineering action:** start P0 on a new implementation branch from `f701c2e…`, beginning with the Aura design primitives, shell adapter and Today vertical slice. Do not change the scoring engine in the same commit as the UI port.


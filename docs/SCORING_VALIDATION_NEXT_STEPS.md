# Scoring Validation: Required Next Steps

This file is the persistent handoff for ongoing NOOP scoring-validation work. Read it before changing or pushing `analytics/scoring-validation`.

## Current reviewed state

At the time this checklist was created:

- `analytics/scoring-validation` was based at `7c700940e2782039876665e7143575b75d31f3e2` before this docs-only commit.
- `analytics/stress-temporal-quality` was `221a8aff9ff2d27d08533efb6ee203275cbc62d6` and exactly one scoring commit ahead of that state.
- `ryanbr/noop:main` had moved substantially ahead of the forked scoring branch (87 commits in the review).

The scoring work should **not** simply be pushed forward on the old base. First reconcile it with current upstream.

---

## Simple summary

The scoring logic is moving in the right direction, but newer upstream NOOP changed some of the data feeding it.

The safe order is:

1. Start from current upstream NOOP.
2. Reapply the existing scoring-validation work.
3. Preserve upstream WHOOP 5 HRV/R-R fixes and baseline-trust rules.
4. Preserve the newer stress-screen performance architecture.
5. Reapply the temporal-quality scoring commit.
6. Run focused cross-platform and causality tests.
7. Only then update the main scoring branch with the verified result.

The key principle is:

> Correct scoring on stale or incorrectly decoded physiological data is still wrong.

---

## 1. Reconcile with current upstream before more scoring changes

- [ ] Fetch the latest `ryanbr/noop:main`.
- [ ] Create a temporary integration branch from the latest upstream head.
- [ ] Replay/cherry-pick the scoring-validation work onto that integration branch.
- [ ] Resolve conflicts there instead of blindly merging upstream into the old scoring branch.
- [ ] Do not force-update the public scoring branch until focused tests pass.
- [ ] Record the upstream base SHA used for the final integration.

---

## 2. Preserve the WHOOP 5 R-R milliseconds fix

Important upstream commit:

`a78e2a665941a84c60a855a17214ebc62d7e617a`  
`whoop5: read the standard-profile R-R as milliseconds (#2195)`

Upstream evidence showed WHOOP 5 sends the relevant R-R words as milliseconds. The older path treated standard-profile values as 1/1024-second ticks, making the resulting intervals about 2.3% low and affecting derived HRV.

Required:

- [ ] Keep WHOOP 5 R-R words as milliseconds where current upstream does so.
- [ ] Do not restore the old WHOOP 5 `ticks * 1000 / 1024` behaviour during conflict resolution.
- [ ] Keep standard BLE conversion for non-WHOOP devices unchanged.
- [ ] Re-run HRV/RMSSD tests after integration.
- [ ] If expected/golden HRV values move because of corrected R-R units, document that cause explicitly rather than hiding the change as a generic fixture update.

---

## 3. Keep HRV over-count protection

Relevant upstream work includes the WHOOP R-R over-count gate and diagnostics, including #1118 and #2129.

Required:

- [ ] Preserve the existing R-R over-count / physiological-integrity gate.
- [ ] An over-counted night must not produce a trusted RMSSD merely because another quality gate passes.
- [ ] Over-counted nights must not seed the HRV baseline.
- [ ] Preserve diagnostics that explain refusal, e.g. `refused=overCount`.
- [ ] Keep this gate separate from temporal-coverage quality. They detect different errors.
- [ ] Review the known deep-window caveat: upstream noted that the deep-window branch may not use the same over-count refusal as the whole-night path. Do not silently change this without dedicated tests and an explicit decision.

Pipeline should remain conceptually:

```text
raw sensor data
    -> transport/unit correctness
    -> R-R physiological integrity / over-count gate
    -> temporal coverage quality
    -> baseline usability
    -> scoring
```

---

## 4. Use per-signal baseline trust

Newer upstream logic increasingly treats each signal's baseline independently.

Required:

- [ ] HR baseline readiness must come from accepted HR history.
- [ ] HRV baseline readiness must come from accepted HRV history.
- [ ] Do not mark HRV baseline usable because enough RHR nights or generic daily rows exist.
- [ ] Prefer the existing `Baselines.foldHistory(...).usable` semantics where applicable.
- [ ] Stale or physiologically implausible observations must not make a baseline look usable.
- [ ] Avoid introducing a new count-only baseline rule when the existing baseline engine already models usability.

In simple terms:

`HR baseline ready != HRV baseline ready`.

---

## 5. Reapply the temporal-quality scoring work after upstream reconciliation

Target scoring-quality commit:

`221a8aff9ff2d27d08533efb6ee203275cbc62d6`  
`stress: add causal temporal signal quality gating`

Required:

- [ ] Reapply this commit after the upstream reconciliation, not before.
- [ ] Replace count-only hourly acceptance with timestamp/coverage-aware quality gating.
- [ ] Enforce a maximum-gap concept so clustered samples cannot masquerade as broad coverage.
- [ ] Keep structured/versioned quality evidence.
- [ ] Keep deterministic `asOf` / causal cutoffs.
- [ ] Future samples or future days must never change an earlier score.
- [ ] Imported/replayed streams must not pass just because they contain many samples packed into a short interval.
- [ ] Re-test cold-start behaviour because the strict prior-hour causal fallback is a real scoring change, not merely diagnostics.

---

## 6. Preserve newer stress-screen performance/threading code

Important upstream commit:

`bccd945f965370b1854d97d49183dbed97e5eaf1`  
`stress: get the screen's work off the main thread and the chart out from behind it (#2191)`

Likely conflict files include:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeBaselines.swift`
- `Strand/Screens/StressView.swift`
- `android/app/src/main/java/com/noop/analytics/DaytimeStress.kt`
- `android/app/src/main/java/com/noop/analytics/DaytimeBaselines.kt`
- `android/app/src/main/java/com/noop/ui/StressScreen.kt`
- `android/app/src/main/java/com/noop/widget/StressWidgetProducer.kt`

Required:

- [ ] Keep upstream's background-thread stress loading architecture on Android.
- [ ] Do not accidentally restore the older UI-thread `loadDaytimeStress` shape during conflict resolution.
- [ ] Keep the stress curve able to publish before optional expensive HRV lenses.
- [ ] Put the new quality-aware scoring engine underneath the newer loading architecture.
- [ ] Avoid making UI performance regress as a side-effect of scoring reconciliation.

---

## 7. Treat homepage/detail stress disagreement as unresolved until proven fixed

Open upstream issue observed during review:

`ryanbr/noop#2219` - homepage stress and detail-page stress can show different results.

Required:

- [ ] Do not use either UI surface alone as the correctness oracle.
- [ ] Prefer one canonical stress calculation/configuration feeding both surfaces where practical.
- [ ] Add/retain a test that equivalent inputs with the same `asOf` cutoff produce the same canonical stress points regardless of caller/surface.
- [ ] Verify timeline display density does not alter daily summary metrics.
- [ ] If Today and detail intentionally render different sampling, make that distinction display-only rather than different scoring rules.

---

## 8. Preserve the existing scoring-validation invariants from `7c700940`

Required:

- [ ] WHOOP import must not persist the old whole-export, future-aware stress formula.
- [ ] Native and imported rows with equivalent RHR/HRV must pass through the same canonical scoring path.
- [ ] Persisted/vendor stress should be a fallback only when physiology cannot be derived.
- [ ] Historical points must use each day's own strictly prior baseline.
- [ ] Adding future days must not change earlier historical scores.
- [ ] Replay/import order must be sorted/deterministic before scoring.
- [ ] Keep ScoreBench blind validation rather than tuning directly against held-out outcomes.

---

## 9. Required focused verification before updating the public scoring branch

Run at minimum:

- [ ] Swift `DaytimeStress` tests.
- [ ] Kotlin `DaytimeStress` tests.
- [ ] Swift/Kotlin `DaytimeBaselines` tests.
- [ ] Swift/Kotlin `StressSignalQuality` tests.
- [ ] `StressModel` carry and causal-history tests.
- [ ] WHOOP 5 R-R decoding/unit tests.
- [ ] HRV over-count/refusal tests.
- [ ] Import tests proving WHOOP importer stress is not persisted.
- [ ] ScoreBench blind-validation checks.
- [ ] Future-data-leakage / causality tests.
- [ ] Swift/Kotlin parity and twin-map checks.
- [ ] Relevant Android compile/tests.
- [ ] Apple app/package build checks covering touched app-target files.
- [ ] Tests covering Today/detail stress consistency or canonical equivalence.

---

## 10. Update rule

Only replace/update the public `analytics/scoring-validation` implementation with the reconciled result after:

- [ ] Latest upstream has been incorporated intentionally.
- [ ] WHOOP 5 R-R correction is present.
- [ ] HRV over-count protections are present.
- [ ] Per-signal baseline usability is preserved.
- [ ] New stress UI/threading architecture is preserved.
- [ ] Temporal-quality commit is reapplied and reviewed.
- [ ] Focused tests are green.
- [ ] Parity checks are green.
- [ ] Final upstream base SHA and final scoring branch SHA are recorded here.

## Do not close/ignore this checklist just because the project compiles

Compilation is necessary but not sufficient. The failure modes being guarded against here are mainly **plausible but wrong numbers**, which are considerably more irritating than a clean compiler error because they look successful.
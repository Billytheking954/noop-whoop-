# NOOP V2 × Aura Phase 2 Implementation Checkpoint

**Date:** 24 October 2026 (UK)  
**Repository:** [Billytheking954/noop-whoop-](https://github.com/Billytheking954/noop-whoop-)  
**Phase 2 branch:** `integration/aura-ui-phase2-20261024`  
**Integration review:** [draft PR #53](https://github.com/Billytheking954/noop-whoop-/pull/53) targeting `integration/aura-v2-candidate-20261024` (PR #52), **not main**.  
**Phase 1 source:** `docs/AURA_V2_COUNCIL_ARCHITECTURE_AND_ACCURACY.md` at `a41f4167789a9d2eff9b5b8823e7bbb2c7351364`.  
**V2 implementation parent:** `f701c2e72f86055291826d1010ec5d57f6d15504`.  
**Aura reference:** `gdorgian/noop@004584b30310f516a060579141038d0e0f1790ba`.

## Scope and safety

This is a **partial implementation checkpoint, not completed Phase 2 and not a release-ready IPA**. V2's `BLEManager`, `Repository`, `AppModel`, database, HealthKit, backup/restore, tracking, scoring, import and offline persistence remain authoritative; none were wholesale replaced with Aura. The user-facing Today preview is **opt-in and defaults off**, with a one-tap return to V2 Today and all existing routes. Production `main`, PR #52 and the previously verified IPA are untouched.

## Implemented

1. Added exact Aura `NoopPalette`, `NoopSpecTokens`, `NoopSpecType`, `NoopSpecMotion`, `NoopSpecPrimitives` and `NoopChargeGauge` sources to the existing `StrandDesign` package. Added fonts, README, original SIL Open Font Licence files, and a V2-aware quiet-motion timeline helper. Registered font faces at the iOS app launch boundary. All code is source-ported, not an upstream branch merge.
2. Added `AuraTodayAdapter`, `AuraRestAdapter`, `AuraFitnessAdapter`, `AuraTrendsAdapter`, `AuraDeviceAdapter` with injectable daily records, optional real timestamps and source IDs. Daily aggregates provide only a day key, **not a measured-at timestamp**. Missing or stale values are explicit; historical trend gaps remain gaps. Merged scores default to unresolved origin instead of falsely claiming live NOOP or WHOOP provenance. Device battery takes real source/time inputs, shows integer percentages and marks old/disconnected readings as stale.
3. Built an **Aura-styled Today preview** using existing repository data and upstream palette/card/type primitives. It shows resolved daily Charge/recovery, HRV, resting HR, sleep and Effort with data caveats. It is controlled by `noop.auraTodayPreviewEnabled` and defaults **false** until end-to-end testing. The full V2 Today view remains reachable.
4. Corrected `Strand/Data/WhoopImporter.swift` so WHOOP CSV absolute skin °C maps to `DailyMetric.skinTempC` and the deviation field stays nil; incremented importer version. Included separately named `skin_temp_absolute_c` time series and updated import column reporting.
5. Added a **legacy data guard** in `RecoveryScorer`: absolute skin temperatures mistakenly stored as deviations (and otherwise impossible deviations outside ±8 °C) cannot enter the Charge temperature penalty. No historic row is rewritten or guessed. Original imported raw CSV values are preserved when the source is available.
6. Added deterministic importer, scoring and presentation-adapter tests. Enabled Phase 2-targeted PR triggers for iPhone app build, Swift packages, source hygiene and localisation. Python CI also runs for the PR.
7. Added a separate `AuraPreview.xcstrings` app string table with focused German, Spanish, French and Portuguese translations. Extended localisation CI to inspect both app tables, retaining checks for user-visible strings. Upstream font licences and notices accompany sources.

## Import safety and historical recovery

The old CSV mapping had stored absolute wrist temperature (normally around 30–35 °C) inside `skinTempDevC`, which NOOP Charge treats as a signed baseline deviation. For *new* imports the correct absolute column is used. For legacy rows, a scoring guard **excludes** the implausible deviation from the Charge term. No automatic SQL rewrite is performed because historic provenance may be ambiguous. To restore a correctly typed value, re-import the original WHOOP export with importer v2 after first creating a restorable backup. Previously stored derived recovery scores may need a separate deliberate recalculation and must not be assumed automatically repaired. This is a pending user-facing recovery workflow, not a completed migration.

## Validation ledger

Check the **exact head SHA of PR #53** in GitHub Actions for the authoritative live result. Source-hygiene, Python and localisation passed on some intermediate commits; intermediate success is not evidence that all final-head CI passed. iPhone simulator compilation and hosted unit tests, Swift packages, localisation and Python **must all be confirmed at the final exact commit** before promoting this checkpoint. No claims of a physical WHOOP BLE test, HealthKit export permission, backup/restore data safety on-device, an on-device installation, accessibility audit or daily-use readiness are made. No validated Aura simulator screenshot has been attached to this document.

## Incomplete / intentionally deferred

- Exact Aura shell/navigation, complete Rest/Sleep, Fitness and workout-detail, Trends/history, Devices/Pairing, Health, Stress, You and Settings **not yet ported as full production screens**. The adapters alone do not equal complete features.
- `NoopDesign.swift`, `NoopHistoryPlot.swift`, the visual-only portions of `NoopNavigation.swift` and `NoopShell.swift` remain to integrate after isolated compile validation.
- Real source-specific times/provenance from `SourcedDailyMetric` and sample-level stores need robust wiring. The daily aggregate adapter deliberately does not invent timestamps or claim per-value source identity.
- Physical WHOOP 4 / 5 / MG pairing, disconnect/reconnect, HealthKit entitlement/writeback and SideStore signing remain hardware-unverified.
- Shadow rolling 28-valid-night baseline and 7-day lnRMSSD experiment are deferred; V2 recovery coefficients and headline algorithm are unchanged except the absolute-temperature input exclusion.
- Full multilingual UI copy, light/dark review, VoiceOver/Reduce Motion check on real devices and screenshot comparisons await Phase 2 visual validation.

## Handoff

1. Confirm PR #53 final exact SHA and inspect complete build/test jobs. Fix all failing compilation/tests before treating this branch as green.
2. Continue with the controlled file-by-file Aura screen/nav integration, preserving V2's existing `NavigationStack`, tab actions, deep links, backup and device management.
3. Add adapter tests with real per-value timestamps and source identity; validate DST/local-day and empty/error states.
4. Validate on an actual iPhone and compatible physical WHOOP strap, including battery and reconnection, before any daily-use recommendation.
5. Only after Phase 2 is complete, move to Phase 3 full regression testing, unsigned IPA build for **the exact validated source commit**, IPA integrity checks and SideStore installation.

**No main merge is authorised.** This file records committed work and blocks instead of declaring unfinished work complete.

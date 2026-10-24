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

- The Aura shell/You hub, Rest, Fitness, Trends and Devices overview now exist **behind an opt-in toggle**. Complete Aura Rest/Sleep editing and timelines, Fitness workout/HR detail, historical presentations, Health/Stress, and settings/pairing polish remain incomplete. A V2 deep link is not a completed Aura screen.
- `NoopDesign.swift`, `NoopHistoryPlot.swift`, the visual-only portions of `NoopNavigation.swift` and `NoopShell.swift` remain to integrate after isolated compile validation.
- Real source-specific times/provenance from `SourcedDailyMetric` and sample-level stores need robust wiring. The daily aggregate adapter deliberately does not invent timestamps or claim per-value source identity.
- Physical WHOOP 4 / 5 / MG pairing, disconnect/reconnect, HealthKit entitlement/writeback and SideStore signing remain hardware-unverified.
- Shadow rolling 28-valid-night baseline and 7-day lnRMSSD experiment are deferred; V2 recovery coefficients and headline algorithm are unchanged except the absolute-temperature input exclusion.
- Full multilingual UI copy, light/dark review, VoiceOver/Reduce Motion check on real devices and screenshot comparisons await Phase 2 visual validation.

## Normal-chat continuation — 24 October 2026

- Continued from PR #53's original `0441f6c3` head without changing `main` or the PR #52 branch.
- Added `Strand/Screens/AuraDetailViews.swift`: Aura-styled Rest (sleep time, efficiency and explicitly estimated stages), Fitness (stored Effort and steps) and 30-day Trends. These use the existing `Repository` and pure adapters, with source uncertainty preserved. Historical chart marks are discrete rather than connecting across missing days.
- Linked the opt-in Aura Today preview into these detail screens; preserved links to V2 `SleepView`, `WorkoutsView` and `TrendsView` for complete editing and reporting.
- Added Aura catalogue labels and translations for the detail navigation; subsequent shell/device translations are recorded below.
- **Commit checkpoint before this documentation update:** `afe9dfe4c7a02b95e22b05662af47cdc9b46dfa8`.
- **Validation:** the original head's Swift packages, Python, i18n and hygiene workflows succeeded; its iPhone simulator build and hosted unit-test steps succeeded, with screenshot capture still in progress when checked. The new changes triggered fresh workflows. **No passing exact-new-head claim is made**; inspect GitHub Actions before promoting this checkpoint.
- **Still missing:** Aura root-shell transformation, full device/pairing redesign, workout detail, sleep editing integrated into Aura, source-specific provenance, complete accessibility visual review, additional localisation, real-hardware BLE/HealthKit tests, final IPA.
- No personal export, raw measurements or fabricated data were added. No changes to BLE, HealthKit, database schema, backup or scoring in this slice.

## Continued integration checkpoint — 24 October 2026 (normal ChatGPT)

**Implementation-head before this documentation commit:** `6bcc01ddb7a4363307ab8384afe95da6be5b0346`. Treat PR #53's live `head_sha` as canonical after this documentation update.

### Additional changes actually pushed

- **Opt-in Aura navigation shell:** When `noop.auraTodayPreviewEnabled` is true, V2's native `TabView` presents Today, Rest, Fitness, Trends and You. When disabled, the classic Today, Health, Activity and More tabs stay intact. Native `NavigationStack` ownership, `NavigationPath` indexing, existing sheet routers, quick actions, route destinations and `main` remain unchanged. Switching shells clears only the repurposed tab navigation paths to avoid stale destinations. A pure `AuraShellTabs` map and regressions cover tab order and edge swipes. This is an Aura-style *integrated navigation treatment*, not full pixel-parity with Aura's custom tab bar.
- **You index:** The same 31 More-index `MoreRow` destinations are reused by an Aura-styled You surface, rather than re-implemented or silently dropped. Original routes to health, stress, data, backup, Apple Health, device management and settings are kept.
- **Device visual integration:** `AuraDevicesOverview` is opted into from existing `DevicesView`. It uses V2's `DeviceRegistry`, `LiveState`, existing `DeviceBatteryPresentation`, `AddDeviceWizard` and `DevicesContent`. The device UI does not own or replace BLE scanning, reconnection, offload, storage or permissions. Missing/disconnected battery shows an em dash rather than a fabricated live percentage.
- **Presentation state:** Aura Rest/Fitness/Trends readings now distinguish loading, available, stale, missing and failed states. Existing `AuraTodayAdapter`, `AuraRestAdapter`, `AuraFitnessAdapter` and `AuraTrendsAdapter` remain the value boundary. Added deterministic tab-order and nil-measurement regression cases.
- **Localisation:** Added translations of new Aura shell, metric-status and device text in the AuraPreview catalogue for English, German, Spanish, French and Portuguese.
- **Source correctness:** No change to the V2 BLE engine, HealthKit bridge, storage/schema, backup/recovery or physiological score weights in this continuation. The earlier absolute-vs-deviation WHOOP skin-temperature safeguards remain, but legacy historic rows are *not* automatically repaired.

### Verification and limitations

- At the starting `1cb55d19` head, Source Hygiene, Python regressions and iPhone localisation **passed**. The Swift package and simulator workflows were running/queued when inspected. Their eventual result must be checked separately.
- Source commits triggered GitHub Actions; old iPhone runs have at times been **cancelled due to branch updates**. Cancellation is not a compiler failure and is **not a pass**. Only complete workflows at the *final exact PR head* establish a validated checkpoint.
- Visual snapshots, a polished Aura custom bottom-bar, comprehensive sleep timing/editing, complete workout detail/HR charts, complete health/stress restyling, per-sample timestamps and source attribution are **not yet finished**. V2 screens remain reachable and authoritative, but a link to the V2 screen does not mean its Aura replacement is complete.
- Physical WHOOP 4/5/MG Bluetooth, HealthKit permissions after SideStore resigning, sleep overnight, actual battery timestamps, restore and 24–72-hour reliability tests are **not tested**. No new IPA is produced by this document. Keep original pre-Aura `f701c2e` IPA as the known structural fallback.
- **Phase 2 is not yet complete or Phase-3 ready.** Confirm final simulator compile + hosted tests, inspect screenshots, then complete the incomplete UI surfaces and data provenance work before promotion. No `main` merge.

## Handoff

1. Confirm PR #53 final exact SHA and inspect complete build/test jobs. Fix all failing compilation/tests before treating this branch as green.
2. Continue with the controlled file-by-file Aura screen/nav integration, preserving V2's existing `NavigationStack`, tab actions, deep links, backup and device management.
3. Add adapter tests with real per-value timestamps and source identity; validate DST/local-day and empty/error states.
4. Validate on an actual iPhone and compatible physical WHOOP strap, including battery and reconnection, before any daily-use recommendation.
5. Only after Phase 2 is complete, move to Phase 3 full regression testing, unsigned IPA build for **the exact validated source commit**, IPA integrity checks and SideStore installation.

**No main merge is authorised.** This file records committed work and blocks instead of declaring unfinished work complete.

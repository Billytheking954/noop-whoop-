# NOOP V2 12.0.0 Reliability Audit — Live Checkpoint

Status: IN PROGRESS  
Audit branch: audit/noop-v2-12-full-bug-review  
Current audit head before this report update: 50555efd5e1bacfcc2ee0eeea6d42af9cc56cf1c  
Frozen main baseline: af9079012ddd4c9023720f4e9eb7ef12c0cd33d4  
Release baseline: 12.0.0 (435)

## Guardrails

- `main` remains frozen at `af9079012ddd4c9023720f4e9eb7ef12c0cd33d4`.
- No merge to `main` has been performed.
- Audit fixes are confined to `audit/noop-v2-12-full-bug-review`.
- Production SpO₂ scoring has not been changed.
- The audit continues after the two initial findings; 12.0.1 is not justified merely by the existence of a bug fix.

## Resolved / classified findings

| ID | Component | Severity | Confidence | Classification | Current state |
|---|---|---:|---:|---|---|
| AUDIT-TIME-01 | Physiological local-day bucketing across DST | P2 | 0.98 | CONFIRMED | FIXED on audit branch at `50555ef`; regression coverage added; package CI, iPhone app build/tests and unsigned IPA workflow all pass. |
| AUDIT-CI-01 | Insight-alert relaunch UI test / notification authorization | P3 | 0.85 | PROBABLE TEST-HARNESS / ENVIRONMENT DEPENDENCY | Original app job attempt failed only `ReferenceJourneyUITests.testInsightAlertPreferenceSurvivesRelaunch()`; rerun of the same `af9079` source passed. Test was hardened at `91ecdce` to treat granted and denied notification authorization as supported outcomes; branch-head iPhone-hosted test now passes. No production defect established. |
| AUDIT-TIME-02 | Physiological-day synthetic/calendar midnight resolver still uses one fixed offset | P3 | 0.95 | CONFIRMED | Rule-aware calendar-day scoring is fixed, but `DayCycleResolver` remains fixed-offset. A DST transition can move its reconstructed midnight by one hour. Current production integration reaches the synthetic fallback only after the open-cycle cap, so impact is narrower than AUDIT-TIME-01. Documented; not auto-fixed pending parity review. |
| AUDIT-SIGN-01 | Unsigned IPA template omitted HealthKit background delivery | P3 | 0.99 | CONFIRMED | The app entitlement requests background delivery but the sideload template dropped it. Fixed at `6ed228e`; packaging now asserts it survives the ad-hoc template. This does not grant the capability to an unsupported signing profile. |
| AUDIT-HK-01 | HealthKit day-key helper freezes the process-start timezone | P2 | 0.97 | CONFIRMED | A static `DateFormatter` captured `TimeZone.current` once, while HealthKit daily queries use the live local calendar. A timezone change without process restart could label new HealthKit buckets using the old zone. Fixed at `263a0b6`; deterministic London/New York DST and zone-difference tests added at `fed83bf`. CI pending. |

## AUDIT-CI-01 evidence

- Workflow run `37651029136`, attempt 1 job `112894089378`: iPhone-hosted test step failed, with the log naming only `ReferenceJourneyUITests.testInsightAlertPreferenceSurvivesRelaunch()`.
- Workflow run `37651029136`, attempt 2 job `112911485898`: passed all steps.
- Both attempts checked out `af9079012ddd4c9023720f4e9eb7ef12c0cd33d4`; the rerun did not contain a source fix.
- The old UI test assumed that tapping the switch would necessarily change its value after at most a short SpringBoard permission prompt.
- Production behavior legitimately resets the switch when notification authorization is denied.
- Commit `91ecdce33a8525f8e1b856619260ba3f3799c53b` changes only the UI test so it waits for and accepts either the authorized persisted-on state or the denied/reset-with-guidance state.
- Exact XCTest assertion text from the first failed `.xcresult` is still unavailable through the currently exposed evidence route; therefore authorization-state causality is probable rather than claimed as proven fact.
- Because an unchanged rerun passed, the evidence rejects a deterministic production regression.

## AUDIT-TIME-01 root cause and fix

Root cause:

- Production score enumeration used a single current fixed GMT offset and advanced historical local-day boundaries in fixed 86,400-second increments.
- Across DST, a civil day is 23 or 25 hours. Delayed sync/recalculation could therefore shift a historical local midnight by one hour and include or omit samples around the boundary.

Fix at `50555efd5e1bacfcc2ee0eeea6d42af9cc56cf1c`:

- Production scoring now enumerates dates with `LocalDayWindows` using `TimeZone.current` and the time zone's rule-aware calendar boundaries.
- `AnalyticsEngine.analyzeDay` accepts exact `calendarDayBounds` for production callers while retaining the legacy fixed-offset fallback for pure callers that do not own a `TimeZone`.
- Daily HR/step reads, sleep read-window end, edited-sleep day assignment, cache windows, legacy score snapshots and step-calibration windows now use the resolved next local midnight rather than blindly adding 86,400 seconds.
- The cache signature now includes `timeZone` as well as the legacy offset, preventing reuse across a zone-identity change with the same instantaneous offset.
- No unrelated scoring architecture was refactored.

Regression coverage includes:

- America/New_York fall-back: 25-hour day.
- Europe/London spring-forward: 23-hour day.
- Asia/Kathmandu ordinary non-DST day: unchanged 24-hour behavior.
- Delayed recalculation after New York fall-back retaining the historical 04:00Z midnight rather than recomputing it as 05:00Z.
- Samples in the repeated fall-back hour and samples just beyond the spring-forward day's real next midnight.
- Sleep read-window end using the actual next local midnight.

## Validation at audit head 50555ef

All observed branch-head workflows completed successfully:

- Swift Packages CI — run `37663060299`: PASS.
- App build (iPhone) — run `37663060277`: PASS.
  - `iphone-build-and-tests` job `112935198224`: PASS.
- Unsigned iPhone sideload IPA — run `37663060388`: PASS.
- Source Hygiene — run `37663060392`: PASS.
- iPhone i18n Coverage — run `37663060358`: PASS.
- Tools Python CI — run `37663060265`: PASS.

This is sufficient CI evidence to treat AUDIT-TIME-01 as fixed on the audit branch, not merely patched.

## Persistence / deduplication review

Reviewed:

- `WhoopStore` file-backed open/migration serialization through `StoreOpenGate`.
- WAL-backed `DatabasePool` use and single-writer GRDB semantics.
- Natural-key/idempotent inserts for decoded streams.
- R-R duplicate handling, sequence keys, emission ordering and source-channel promotion.
- Sleep-session merge/dedup and timestamp-heal protections reviewed in the prior checkpoint.
- Cross-stream analysis fingerprints used to force rescoring after delayed non-HR data lands.

Current classification:

- No new P0/P1/P2 persistence corruption or duplicate-scoring defect confirmed in this pass.
- Existing R-R migration/test coverage explicitly pins equal-beat retention, emission order, legacy rows and the known batch-local ordering behavior.

### AUDIT-STORE-01 — instrumentation retention cap can drift across repeated short process lifetimes

- Component: `ppgWaveformSample` / `v18AuxSample` retention.
- Severity: P4.
- Confidence: 0.95.
- Classification: CONFIRMED design limitation, low severity.
- Evidence: retention sweeps are triggered by in-memory per-store row counters. A process that repeatedly writes fewer than the prune threshold before termination can reset the counter each launch and remain above the nominal newest-N cap indefinitely. The source comments explicitly acknowledge this behavior.
- Impact: storage growth only; no score, sleep, recovery, strain, stress or SpO₂ production calculation is changed.
- Action: documented, not fixed under the audit's automatic-fix threshold. A once-per-session/open bounded sweep would be the narrow future remedy if storage growth becomes material.

## Migration registration / safety review

Reviewed the ordered GRDB migrator through current schema migrations, including the higher-risk rebuild/update migrations:

- v24 R-R PK rebuild copies every previously representable row with `seq = 0` before replacing the table.
- v26 efficiency heal is predicate-scoped to values (> 1.5), leaving valid 0–1 fractions unchanged and has dedicated upgrade testing.
- Later schema changes are predominantly additive nullable columns/new tables, preserving old rows and absence semantics.
- Migration tests pin R-R primary-key shape, equal-beat preservation, v30 ordering behavior, legacy-null behavior and the v26 data heal.
- Concurrent file open/migration is serialized before construction of a pre-migrated `WhoopStore`.

Current classification:

- No migration-registration or destructive-upgrade P0/P1/P2 defect confirmed.
- Continue auditing latest migration tails and backup/restore compatibility, but no speculative production change is justified.

## Rejected / downgraded false positives

- Pre-merge → release merge changed zero files, so the first UI-test failure was not caused by merge content.
- `SleepStagerV2.respRegularity` forced unwraps are guarded by the minimum beat count.
- A theoretical future-sleep empty/reversed active window is blocked by upstream timestamp plausibility/heal gates on the production ingest paths reviewed so far.
- The experimental `HealthKitObservationProvider` is not wired into the shipping bridge and is not a production defect.
- The first insight-alert UI-test failure is not evidence of a deterministic app regression because the unchanged-source rerun passed.

## Audit areas completed or substantially reviewed

- BLE core review from the earlier audit phase; not repeated.
- DST/local-day scoring path and production fix.
- Insight-alert UI-test nondeterminism.
- Core persistence natural keys, dedupe, open serialization and R-R storage invariants.
- Migration registration and representative destructive/data-heal migrations.
- Activity-detector decision paths and deterministic tests.
- Core score-input guards.
- Initial HealthKit bridge sequencing/write guards from the earlier checkpoint.

## Remaining priority work

1. Finish persistence mutation call-site review outside the core stream insert path.
2. Finish backup/restore + migration edge compatibility.
3. Re-check end-to-end timezone/cycle assignment after the DST change, including travel/time-zone changes.
4. Complete sleep-pipeline recalculation and edit/merge edge cases.
5. Complete HealthKit authorization/revocation/read/write behavior.
6. Audit Swift concurrency warnings, cancellation and race boundaries.
7. Revisit activity overlap/retry and automatic detection edge cases.
8. Verify scoring-input integrity after delayed/off-order sync.
9. Audit background lifecycle and reconnect-triggered rescoring.
10. Remaining BLE edge cases not already covered.
11. Sideload/re-signing, entitlements, widget/app-group behavior.
12. UI state reliability.

## Timezone / physiological-cycle follow-up

### AUDIT-TIME-02 — fixed-offset day-cycle boundary remains outside the DST fix

- Severity: P3; confidence 0.95; CONFIRMED.
- `DayCycleResolver.calendarWindow`, `fallbackMidnight` and `activeWindow` still derive local midnight from one `offsetSec` with 86,400-second arithmetic.
- On a DST transition date that can move the resolved midnight by one hour. The normal calendar-day scoring loop no longer uses this logic after AUDIT-TIME-01.
- The shipping physiological-cycle integration reaches the synthetic-midnight branch only after its 40-hour absolute open-cycle cap, so the practical impact is narrower.
- The subsystem documents a Kotlin twin. No one-platform production correction is being made until parity can be reviewed.

### Time-zone travel semantics — evidence gap, not yet a defect

- A scoring pass binds `TimeZone.current` at recomputation time; the inspected raw/persisted day model does not persist a source-zone identifier per historical sample/day.
- A major device-zone change can therefore make historical wall-clock heuristics use the new zone. The day cache does invalidate on zone identifier changes, so this is not stale-cache behavior.
- The intended product invariant for historical acquisition-zone versus current-zone interpretation is not stated in the inspected contract. This remains an architectural/evidence question rather than a confirmed bug.

## HealthKit timezone / day-assignment review

### AUDIT-HK-01 — HealthKit day labels could remain in the old timezone until relaunch

- Severity: P2; confidence 0.97; CONFIRMED.
- The bridge used one static `DateFormatter` whose `timeZone` was assigned `TimeZone.current` at first access.
- HealthKit aggregate queries construct `Calendar.current` for each sync, so after a live device-zone change query buckets and NOOP's day labels could disagree until process restart.
- Commit `263a0b632b4baa1f605206ed380211b032e0dc34` removes the process-frozen formatter. Day-keying now uses `LocalDayWindows` with an auto-updating zone, matching the rule-aware scoring boundary contract; reverse day-to-date conversion resolves the actual local midnight through the same helper.
- Commit `fed83bfd6a43352d347ae99763bcb222f00725cf` adds deterministic regression coverage proving the same instant maps to different civil dates in London/New York and proving real spring-forward/fall-back midnights.
- The change is confined to HealthKit civil-day labelling/parsing. It does not change BLE, workout detection, production SpO2 scoring, recovery, strain, stress or sleep algorithms.
- Validation is pending on the new audit head; do not treat the fix as release-ready until the iPhone-hosted tests and app build are green.

## Sideload / re-signing review

### AUDIT-SIGN-01 — HealthKit background-delivery entitlement dropped by unsigned IPA template

- Severity: P3; confidence 0.99; CONFIRMED.
- `StrandiOS/Resources/NOOP.entitlements` requests `com.apple.developer.healthkit.background-delivery = true`.
- `Tools/prepare_iphone_sideload.sh` preserved App Group and base HealthKit but omitted background delivery.
- Commit `6ed228e2798704608fd29d72eb468bc2981b1bdc` adds the entitlement and a packaging-time assertion.
- This preserves a requested capability only. A sideloader/signing profile can still strip HealthKit or App Group entitlements when that profile is not entitled to them; the runtime HealthKit check correctly reports `.entitlementMissing` in the no-HealthKit case.

## WHOOP trial evidence to collect while still available

Useful normal-device comparisons, if encountered during the next 2–3 days:

- One ordinary overnight sleep: official WHOOP sleep start/end vs NOOP after morning sync.
- One ordinary workout: start/end and HR trace/summary comparison.
- One force-close/relaunch followed by reconnect and sync.
- One delayed sync after wearing the strap disconnected for a while.

No artificial physiological or unsafe test is required.

## Release recommendation

Keep 12.0.0 on `main` unchanged for now.

The audit branch has a CI-validated fix for the confirmed DST P2, but a 12.0.1 candidate should wait until the remaining high-priority audit areas have been checked for additional high-confidence P0/P1/P2 defects and any such findings are fixed or consciously deferred.

## Persistence / backup follow-up

### AUDIT-BACKUP-01 — pre-restore rollback snapshot omitted committed WAL-only pages

- Severity: P2; confidence 0.99; CONFIRMED.
- The restore path documented a snapshot of the current database "+ sidecars" but copied only the main `.sqlite` file before deleting the live `-wal` / `-shm` files.
- NOOP's production store uses WAL. A committed transaction can therefore be visible to SQLite while still existing only in `-wal`; copying the main file alone yields a valid but stale rollback snapshot.
- Independent SQLite reproduction confirmed the failure shape: after a checkpoint, a committed row held in WAL disappeared from a main-file-only copy.
- Regression commit `91ac97b364150d96ac6f66e0ab66cabf7b104aeb` adds a real WAL-backed restore test and requires the returned sidecar to contain the WAL-only committed row.
- Fix commit `8b7b0deb819648ff41820df9b7777bd6761cdfcb` replaces the raw main-file copy with SQLite's online backup API, producing a transactionally consistent self-contained sidecar while the live DatabasePool remains open.
- This changes only pre-import rollback preservation. It does not alter scoring, BLE, sleep, workout detection, HealthKit ingestion/write-back, or SpO₂ behaviour.
- CI validation is pending at this checkpoint; do not treat the fix as release-ready until the targeted iPhone test/build and relevant package/full workflows are green.

## HealthKit authorization follow-up

### AUDIT-HK-02 — read-only HealthKit grants were not resumed after relaunch

- Severity: P2; confidence 0.98; CONFIRMED.
- A successful HealthKit authorization request is treated as `.authorized` in-process because Apple deliberately does not expose read authorization state.
- On the next launch, however, `refreshAuthIfPreviouslyGranted()` resumed only when at least one SHARE/write type reported `.sharingAuthorized`.
- A user who allowed reads but denied every write could therefore sync successfully until relaunch, then remain `.unknown`; foreground sync and live delivery would never start automatically even though the prior consent flow completed.
- The bridge already persists the authorization-type signature only after a successful request. Commit `a601dcba7e0d09be9146c5bda92c3d1071904933` uses that durable prior-request evidence in addition to the legacy any-write-granted signal.
- Commit `6093b79141e5d05e1add65bde0b2e54337385657` adds deterministic coverage for read-only prior grants, fresh installs and legacy write-grant resumes.
- This does not claim HealthKit can reveal whether reads are currently allowed; it preserves the existing honest contract that successful consent permits queries, which may return empty if the user denied or later revoked reads.
- CI validation is pending on the current audit head.

## Migration/provenance follow-up

### AUDIT-MIG-01 — backup/version provenance reported stale GRDB schema version

- Severity: P3; confidence 1.00; CONFIRMED.
- The live GRDB migrator is pinned by the schema oracle as a unique sequential chain through `v47-rr-whoop5-fill`, but `WhoopStoreInfo.schemaVersion` still reported `18`.
- That marker is written into `manifest.json` for every `.noopbak` and into `APP_VERSION_CHANGED` events, so forensic/export provenance could falsely claim schema 18 for a database actually migrated through v47.
- This does not change migration execution or stored physiological data; GRDB's own `grdb_migrations` bookkeeping remains authoritative.
- Commit `7a61b8de7680c2a46ec891926c9d806657081cb0` updates the platform-scoped provenance marker to 47.
- Commit `11dd086c226128424279b52ca9fb69d6f245a7f9` replaces the stale literal test with an invariant requiring the marker to equal the registered migration count, preventing the same drift on the next migration.
- Classified as an isolated, low-risk P3 metadata fix; no scoring, BLE, HealthKit, sleep, workout, or SpO₂ logic changed.

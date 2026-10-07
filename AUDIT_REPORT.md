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

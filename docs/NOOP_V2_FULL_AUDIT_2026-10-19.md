# NOOP V2 reliability audit — 19 October 2026

## Status and release boundary

This is a validation candidate based on the current `main` plus the restore-hardening work from PR #48 and the narrowly scoped reliability fixes listed below. It is not yet a release approval. CI must pass for this exact branch head, then physical iPhone / HealthKit validation is still required.

The audit intentionally does not change production Recovery, Strain, Stress, or sleep-score coefficients; the WHOOP BLE protocol; or production SpO₂ usage. Experimental SpO₂ remains instrumentation-only. The timezone changes correct which real local-day interval is supplied to scoring, not the score formula.

## Fixes included in this candidate

- **Restore/data integrity:** staged restore validation checks legacy SQLite WAL headers/checksums and page sizes before replacement, produces a self-contained snapshot that includes committed WAL pages, checks file removal/replacement and verifies the restored database. A process-wide write barrier drains writes and blocks stale GRDB pools through relaunch. Recovery failures are reported honestly and recovery copies are retained. (PR #48 code and tests.)
- **HealthKit read errors versus empty results:** explicit sleep/workout query failures no longer behave like authoritative empty data and cannot replace a previously imported workout row with empty metrics. Route-query errors terminate the continuation even if HealthKit never reports `done == true`.
- **HealthKit partial permissions:** sparse/non-readable results preserve previously stored non-nil fields through `mergeAppleHealthReadRows`; a nil value alone is not treated as a deletion. Successful reads still update observations that were actually returned.
- **Workout ownership:** route and HR reads are scoped to the workout itself, avoiding contamination from other workouts with overlapping times.
- **Timezone correctness:** production scoring receives bounds from local calendar-date rules rather than treating each day as 86,400 seconds. HealthKit day keys and parsing use the supplied/auto-updating timezone rather than a formatter frozen to the timezone at first access. Regression tests cover 23-hour and 25-hour days and same-instant day labels in different zones.
- **Post-import scoring:** successful Apple Health syncs queue a rescore of Watch-derived recovery after updating source data, instead of leaving an invalidated recovery blank until another unrelated trigger. Failed syncs still refresh visible state but do not schedule this rescore; Shortcuts-based Health imports also queue it.
- **Import error reporting:** activity-file HR/step persistence errors propagate instead of reporting a successful import with missing dependent data. Detected-workout suggestions remain open if saving the manual workout fails.
- **Backup provenance:** the backup manifest reports the current GRDB schema version rather than stale metadata. Migration execution is unchanged.
- **Sideload consistency:** the unsigned IPA preparation script preserves and checks the HealthKit background-delivery entitlement. The notification-permission UI test accepts supported denied-permission behaviour instead of assuming every simulator grants access.

## Known gaps — not claimed as fixed

1. **HealthKit deletion reconciliation remains incomplete (P2).** A HealthKit deletion tombstone exposes an object UUID/type but not its original timestamp, while aggregate caches do not carry durable identity for every source object. The candidate detects deletion-bearing observer wakes and rereads a bounded horizon, but it does not claim complete exact-row reconciliation. Do not solve this by clearing/replacing the entire Apple Health source window: denied read authorization can look like empty data and would risk deleting valid last-known measurements. A complete solution needs a durable HealthKit-object identity/tombstone ledger and explicit, tested deletion semantics.
2. **Physiological-cycle DST edge (P3).** The rare synthetic-midnight fallback in `DayCycleResolver` retains fixed-offset arithmetic. The normal production day-scoring window is corrected, but this remaining path needs a timezone-rule-aware contract and Kotlin parity review.
3. **Historical sleep clock heuristics (P3).** Some historical session-selection heuristics still use one current GMT offset rather than the session date's timezone rule. Near DST/travel boundaries this can shift clock-time classification. The broader fix needs a date-aware selector and cross-platform parity tests.
4. **Instrumentation retention bound (P4).** A per-process write counter can under-prune if the app repeatedly exits before reaching the prune threshold. A bounded sweep on open/session is the likely narrow fix; storage impact should be measured before changing it.
5. **Device and release validation.** CI/simulator tests cannot establish physical WHOOP BLE reconnect/offload behaviour, SQLite restore followed by force-quit/relaunch on a signed iPhone, HealthKit entitlement/grant/revocation behaviour, or actual signed-release provenance. These remain required before calling an IPA production-ready.

## Verification rule

Only CI results attached to this candidate's exact head count. Results for main, PR #37, PR #47, PR #48, or an earlier commit are not substitutes. Likewise, green CI validates software tests and packaging gates; it does not close the device-level gaps above.

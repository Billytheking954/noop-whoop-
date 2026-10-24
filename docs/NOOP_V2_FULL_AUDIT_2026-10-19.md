# NOOP V2 reliability audit — 19 October 2026

## Status and release boundary

This is a validation candidate based on the current `main` plus the restore-hardening work from PR #48 and the narrowly scoped reliability fixes listed below. It is not yet a release approval. CI must pass for this exact branch head, then physical iPhone / HealthKit validation is still required.

The audit intentionally does not change production Recovery, Strain, Stress, or sleep-score coefficients; the WHOOP BLE protocol; or production SpO₂ usage. Experimental SpO₂ remains instrumentation-only. The timezone changes correct which real local-day interval is supplied to scoring, not the score formula.

## Fixes included in this candidate

- **Restore/data integrity:** staged restore validation checks legacy SQLite WAL headers/checksums and page sizes before replacement, produces a self-contained snapshot that includes committed WAL pages, checks file removal/replacement and verifies the restored database. A process-wide write barrier drains writes and blocks stale GRDB pools through relaunch. Recovery failures are reported honestly and recovery copies are retained. (PR #48 code and tests.)
- **HealthKit read errors versus empty results:** explicit sleep/workout query failures no longer behave like authoritative empty data and cannot replace a previously imported workout row with empty metrics. Route-query errors terminate the continuation even if HealthKit never reports `done == true`.
- **HealthKit partial permissions:** sparse/non-readable results preserve previously stored non-nil fields through `mergeAppleHealthReadRows`; a nil value alone is not treated as a deletion. Successful reads still update observations that were actually returned.
- **Workout ownership:** route and HR reads are scoped to the workout itself, avoiding contamination from other workouts with overlapping times.
- **Timezone correctness:** scoring windows, HealthKit day keys, synthetic-midnight fallback, historical sleep grouping, overnight checks, and sleep staging now use the time-zone rules at the relevant historical instant. Tests cover DST transitions in Europe/London and Australia/Sydney, alongside 23-hour/25-hour day windows.
- **Post-import scoring:** successful Apple Health syncs queue a rescore of Watch-derived recovery after updating source data, instead of leaving an invalidated recovery blank until another unrelated trigger. Failed syncs still refresh visible state but do not schedule this rescore; Shortcuts-based Health imports also queue it.
- **Import error reporting:** activity-file HR/step persistence errors propagate instead of reporting a successful import with missing dependent data. Detected-workout suggestions remain open if saving the manual workout fails.
- **HealthKit deletion safety:** exact workout and low-volume sample identities support safe tombstone handling. Unmatched identities and empty/permission-hidden reads do not authorize broad deletion; aggregate deletion reconciliation remains incomplete.
- **Strain input quality:** strain refuses duplicate or out-of-order heart-rate timestamps with a diagnostic; duration helpers do not turn negative gaps into positive exercise time.
- **Optional Oura callback safety:** duplicate query parameter names are rejected before OAuth state validation instead of trapping dictionary construction.
- **Generic heart-rate reconnect:** the standard-HR source uses bounded backoff and explicit stop cancels pending reconnects.
- **Backup disclosure:** iOS permission copy and privacy documentation distinguish NOOP network behavior from user-managed iOS device backups; the database remains in the default backup policy.
- **Backup provenance and HealthKit deletion identity:** the backup manifest reports the current GRDB schema version. Migration v48 adds a durable HealthKit workout UUID-to-row-key ledger; observer tombstones can now delete only the matching Apple Health workout row in the same transaction as its identity removal. Migration execution for existing versions remains additive.
- **Sideload consistency:** the unsigned IPA preparation script preserves and checks the HealthKit background-delivery entitlement. The notification-permission UI test accepts supported denied-permission behaviour instead of assuming every simulator grants access.

## Known gaps — not claimed as fixed

1. **HealthKit deletion reconciliation is now partial and non-destructive (P2).** Migration v48 records UUID-to-start/sport/day identity for workouts observed by the live HealthKit sync. A confirmed workout UUID tombstone removes only its exact Apple Health workout row and identity mapping, transactionally; replay is idempotent and the anchor is held if persistence fails. Existing cached workouts that have never passed through the new ledger may still be impossible to map, and deletion of daily aggregate samples is still not reconciled: HealthKit intentionally hides read permission, so an empty aggregate read cannot distinguish real deletion from denied/limited access. Do not clear or replace an entire source window on empty reads. Full aggregate deletion support needs explicit per-sample identity/tombstone semantics without interpreting unreadable data as absent.
2. **Score validation and calibration.** Recovery, Rest, sleep stages, and HRmax/RHR personalization remain estimates; this work does not establish agreement with WHOOP, PSG, or clinical measurements. Do not describe these values as equivalent or clinically validated without an independent held-out dataset.
3. **UI and device acceptance.** The existing UI journeys are selective. Physical iPhone/HealthKit/WHOOP testing is still needed for restore/relaunch, permissions, BLE reconnection, overnight collection, sensor completeness, battery impact, and installation after re-signing.
4. **Instrumentation retention bound (P4).** A per-process write counter can under-prune if the app repeatedly exits before reaching the prune threshold. A bounded sweep on open/session is the likely narrow fix; storage impact should be measured before changing it.
5. **Device and release validation.** CI/simulator tests cannot establish physical WHOOP BLE reconnect/offload behaviour, SQLite restore followed by force-quit/relaunch on a signed iPhone, HealthKit entitlement/grant/revocation behaviour, or actual signed-release provenance. These remain required before calling an IPA production-ready.

## Verification rule

Only CI results attached to this candidate's exact head count. Results for main, PR #37, PR #47, PR #48, or an earlier commit are not substitutes. Likewise, green CI validates software tests and packaging gates; it does not close the device-level gaps above.

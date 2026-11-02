# NOOP V2 stabilisation evidence — 31 October 2026

Branch: `feature/noop12-clean-integration-20261027`. Starting remote HEAD independently
confirmed through PR #65 and a fresh clone: `02f52adc566e90fcf56c7ad83c6244516727d49d`.
Both #65 and #63 were open drafts and unmerged. The working checkout started clean.
No user database, backup, installation or paired strap was accessed.

## Starting evidence and architecture

- Latest published pre-release: `noop-v2-phase5-pr65-57f38adbd79a`, source
  `57f38adbd79ae880b63645ed7810604a05204932`. GitHub asset digest:
  `96a2bc6119ca87b440aad97c90ab6bcf26caccdf88ee1f94136123d7b397a956`.
  This metadata was checked; the binary has not been independently reverified in this session.
- The four portable/source workflows passed on starting HEAD. iPhone build run
  `41116831471` and IPA run `41116831375` did not pass: attempts 1 and 2 had cancelled jobs,
  no runner assigned and no executed steps. That is not evidence of a source compilation failure.
- Store: WhoopStore actor, GRDB DatabasePool/WAL, serialized open/migrate gate,
  schema 49 with forward-only refusal and v48/v49 compatibility tests. No backend replacement needed.
- Startup: AppModel resolves registry/active device, reads 120 saved days, then starts sources;
  full 4,000-day read follows. Today waits for the first cache publication. Existing generation
  guard and off-main merge are retained. `requestedHistoryDays` must never shrink.
- BLE: existing manager/collector/backfiller retain CRC gates, commit-before-ack behavior,
  reconnect policy and WHOOP 5 family handling. Hardware behavior cannot be inferred from source.
- HealthKit: canonical health packages and existing app import/export paths remain; genuine SDNN,
  RMSSD, deletions, author identity and anchored cursor semantics need their existing regressions
  and device checks. No physiology/scoring threshold changes are authorized by this investigation.

## Issue checklist

| Area | Initial classification | Evidence / required action |
|---|---|---|
| 15-second launch, blank cards | Confirmed user report; bottleneck unmeasured | Existing trace measures publication/calculation, not paint. Add stage timings; collect device results. |
| Overlapping cache refreshes | Confirmed implementation defect | Independent readers; generation assigned after store-open suspension; active-device change did not invalidate pending reads. Coalesce and cover with controlled races. |
| Cancelled Today history caching | Confirmed implementation defect | Cancelled task could save history cache; guard sequence/cancellation before cache and completion marker. |
| Full history lost after 120-day refresh | Previously fixed; verify | `9b2a253b`, SavedHistoryWindowTests. Retain non-shrinking range. |
| Saved cache before BLE; failed reads preserve cache | Previously fixed; verify | ColdStartHistoryLoadingTests, SavedHistoryRefreshFailureTests. |
| Schema v48/v49 and WAL backups | Previously fixed; verify | Existing migration, schema oracle and online-backup tests; do not change migrations. |
| Offline database access | Implemented; device/simulator verification outstanding | Seeded tests do not prove real user's history is complete. |
| Scrolling, navigation latency, CPU, graphs | Untested on device | Existing off-main merge/cadence/cache optimizations; Instruments/MetricKit and mini UI journey needed. |
| iPhone and WHOOP battery drain | Blocked by physical testing | Need matched-duration baseline and candidate trials; no battery saving claim. |
| WHOOP reconnect/live HR/partial sync | Blocked by physical testing | Run protocol/reconnect/continuation tests, then strap interruption and app-relaunch checks. |
| HR/RHR/HRV/sleep/recovery/readiness/reserve | Existing implementations; accuracy not established | Preserve algorithms. Automated boundary/provenance tests cannot establish physiological accuracy. |
| HealthKit import/export/dedup/deletions | Needs automated and physical verification | Preserve canonical ingestion/exports and authorization state. |
| Workout false positives/duplicates/future dates | Reported; current symptoms unverified | Existing gap rule, clock gate, suggestion-only creation and cross-source dedup; inspect confirmation/save races. |
| Hero rings/calendar/tabs | Existing simulator tests; rerun | ReferenceJourneyUITests uses synthetic fixtures. |
| Graph details/time ranges/missing-data messages | Untested comprehensively | Check existing chart selection and day-aware windows; do not label all graphs verified from screenshots. |
| Test Centre/Night Lab/daily focus/device settings | Untested comprehensively | Preserve existing routes and battery/device experience; inspect specific reproducible failures. |
| BAT-04/05/06/08, NAV-04, TOD-03/05/08/09, HLT-07/08, ACT-09, PER-02/05, UI-01/10 | Original definitions unavailable | Exact IDs absent from checkout and searches of relevant PR discussions; BAT-04 issue search returned none. Do not invent original steps or mark passed. |
| Full release gates | Not passed at starting HEAD | All six must pass on final source before publication. No old IPA may be relabelled. |

## Validation environment

Windows host, no Swift/Xcode/Simulator. Bundled Python 3.12.14 available. GitHub macOS CI is
the executable app/package validation path. Local sandbox temp permissions required workspace-local
TEMP/TMP. Initial full Tools discovery: 36 tests, four source-reference path-format failures;
these are real Windows/inside-repository fixture assumptions, separate from app behavior.

## Implemented candidate changes (automated execution still required)

- `d4819dc9`: coalesce concurrent repository refreshes with one trailing read; invalidate
  in-flight results on active-device changes; preserve the non-shrinking history window.
  Add controlled suspension tests and local phase timings/Instruments signposts. Cancelled
  Today tasks cannot mark or cache obsolete history loads as complete.
- `7268e72b`: report real workout write success, keep failed confirmations retryable, preserve
  exact detected end seconds, and atomically check all workout namespaces before inserting a
  confirmation. Existing imported/manual data is never overwritten by confirmation. Move the
  pure HR detection/shadow scan off the main actor; all detector policies remain unchanged.
- `59a6162d`: read daily/sleep/metric inputs in one GRDB read snapshot, using the existing
  decoders/queries; coalesce source rows and deduplicate sleep off the main actor. Expose failed
  cache reads separately from empty/loading, retaining previous data with a retry affordance.
  Add snapshot/commit consistency, nil-versus-zero and unavailable/retry regressions.
- Make source-reference tests use a controlled relative fixture root so Windows separators
  and a TEMP directory inside the checkout do not create false failures. Preserve exact message,
  symbol and missing-file assertions. Run all 36 retained tool tests on Linux and Windows CI.

Local result after the fixture correction: **36/36 Tools tests pass**, 1.914 seconds on this
Windows host; protocol arithmetic examples pass; 88 source references across 28 files pass.
Source-comment hygiene, iPhone-only invariants and localisation regression/focus-locale gates
also pass locally. None is an iPhone launch, frame-rate or physiological measurement.

No numeric iPhone startup, CPU, frame-rate or battery measurement has been obtained. The two-second
target remains unverified. Do not describe the reported 15-second delay as resolved from these changes.
No BLE reconnect, charging, overnight capture, HealthKit authorization or physiological accuracy
claim is made. No health algorithm, detector threshold, database migration or schema version changed.

Original physical failure IDs remain unresolved as test definitions; the checklist above is an
additional test plan, not a reconstruction or PASS verdict for those missing definitions.

Final cancellation review: selected-day and history card values now accumulate in locals and
commit to visible Today state only after the day/refresh identity and cancellation check, with
no suspension inside the commit. Hosted sleep/stress also reject superseded results. This closes
the transient UI overwrite that a cache-only guard did not prevent. The existing architectural
startup suite guards this ordering; real rapid date-navigation rendering still needs UI/device evidence.

The earlier ChatGPT chat “Physical Test Planning” was also inspected. It expressly labelled its
failure-ID mappings as **proposed retest focuses**, with original definitions missing. Those mappings
are not original test definitions or physical PASS evidence, and have not been promoted to either.

## Physical checklist — iPhone 13 mini and WHOOP 5.0

Preserve the installed app data, current pairing, database and backups. Do not uninstall/reset.

1. Cold-launch offline, Bluetooth off: time until saved hero/cards appear, open recent and year-old
   dates, visit other tabs and return. Repeat three times; record distribution and Test Centre timings.
2. Restore Bluetooth: reconnect existing strap, check live HR and one manual sync. Interrupt Bluetooth
   mid-sync and resume; check saved history, duplicates and last-completed-sync timestamp.
3. Background/foreground, force-quit/reopen and overnight: confirm stored data stays available;
   distinguish missing/unavailable values from zero. Note WHOOP subscription state.
4. Inspect 24–26 October 2026 UK DST nights, historical workouts and date selection. Compare the same
   daily values on cards, details and graphs; no future workout or duplicated imported activity.
5. Tap all hero rings/metric cards; inspect graph timestamps and ranges, Test Centre disclosure,
   Night Lab, daily focus, battery percentage/charging and dedicated device settings. Check large text.
6. Compare scrolling/frame hitches and navigation during sync with offline behavior. Collect local
   Instruments signposts/MetricKit evidence when available. For battery compare equal-length sessions
   with similar sync volume, screen brightness and radios; simulator CPU is not device battery proof.

No physical item has been marked PASS in this session. Release must remain a pre-release until those
checks are actually performed, even if all automated checks pass.

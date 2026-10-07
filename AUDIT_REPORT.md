# NOOP V2 12.0.0 Reliability Audit — Checkpoint

Status: IN PROGRESS  
Audit branch: audit/noop-v2-12-full-bug-review  
Baseline: af9079012ddd4c9023720f4e9eb7ef12c0cd33d4  
Release: 12.0.0 (435), frozen reference  
No production code changed.

## Live state

- main remains at the known-good baseline at this checkpoint.
- The audit branch remains based on the same baseline.
- The merge from ff6fd86fb0317549b2e5cca87d5fe714a62c32b7 to the baseline has zero changed files.
- App build workflow run 37651029136 failed its iPhone-hosted test step. A job rerun is in progress (attempt 2; job 112911485898).
- Initial failed test: ReferenceJourneyUITests.testInsightAlertPreferenceSurvivesRelaunch(). The 80,174,580-byte test-results artifact is available, but the current file-transfer tool rejects artifacts over 32 MiB. Job logs show the failing test name but not its XCTest assertion/stack.
- The successful pre-merge run 37501984692 used the same source tree (zero-file diff) and matching macOS 26 / Xcode 26.6 / iPhone 17 Pro iOS 26.4.1 environment.

## Current findings

| ID | Component | Severity | Confidence | Status | Evidence and next action |
|---|---|---:|---:|---|---|
| AUDIT-CI-01 | iPhone UI test / notification permission | P3 | 0.65 | PROBABLE | Test toggles “Measured changes,” expects the value to change, and only conditionally taps the SpringBoard “Allow” button. Production view resets the preference to false on denied authorization. This creates a plausible permission-state/test-order dependency. Await rerun and obtain exact .xcresult failure before changing the test. No production defect established. |
| AUDIT-TIME-01 | Physiological-day bucketing around DST | P2 | 0.75 | PROBABLE | AnalyticsEngine.analyzeDay uses fixed-offset 86,400-second windows. LocalDayWindows.swift explicitly documents that it is not wired to scoring and that the answers diverge by an hour around DST; its tests pin the disagreement. Confirm the scoring caller’s offset selection and quantify affected assignments before proposing the larger boundary correction. No code changed. |

No confirmed production bugs at this checkpoint.

## Work completed in this continuation

- Refreshed the live run and job state; inspected the first attempt’s job steps/logs, artifacts, and the successful pre-merge run.
- Inspected the failed UI test, notification settings view, scheduler, and policy.
- Reviewed WhoopStore open/migration serialization, WAL setup, foreign-database quarantine, sleep deduplication/merge, and timestamp-heal logic.
- Reviewed AnalyticsEngine day filtering and day-cycle implementation/tests, including the disconnected DST-aware helper.
- Reviewed HealthKit permission handling, observer registration/coalescing, anchored sync sequencing, failed-read write guards, save-before-retire, stable external UUID keys, and workout orphan reconciliation.
- Reviewed the HealthKit observation provider’s anchored batch/cursor design; it is explicitly not wired into the shipping bridge.
- Reviewed activity detector decision paths and existing deterministic tests; no confirmed defect found.
- Reviewed strain-score input guards and tests; no production-reachable invalid-input defect established.

## Validation available

- Earlier audit checkpoint: Swift package CI passed 13 jobs; unsigned IPA workflow passed.
- Earlier app workflow: simulator build passed; iPhone-hosted tests failed as above.
- Current job rerun is pending. No local checkout/Xcode runtime is available in this workspace, so local iOS builds and XCTest runs cannot be reproduced here.
- No regression tests or production fixes have been added.

## Remaining audit work

- Diagnose the current rerun and extract exact XCTest failure evidence if available.
- Complete migration-registration and schema-upgrade review.
- Trace the live scoring caller’s timezone offset and test DST/timezone-change behavior end to end.
- Complete persistence write/update/dedup callsite review and sleep-stage/recalculation audit.
- Complete HealthKit partial-read/revocation and duplicate-write review.
- Complete concurrency/task-cancellation and background lifecycle review.
- Complete end-to-end activity overlap/retry and scoring-input invariants review.
- Inspect iPhone UI state, entitlements, and sideload/re-signing behavior.
- Run relevant tests and full iPhone build/IPA workflows after any justified changes.
- Capture real-device WHOOP sync, reconnect, sleep, activity, and timestamp comparisons before trial expiry.

## Release recommendation

Keep 12.0.0 for now. Do not prepare 12.0.1 unless the audit confirms a production defect, its root cause, a regression test, and successful relevant CI.

# Classic V2 interface on the NOOP 12 rebuild

Base: upstream v12.0.0 (`7acce06c`). Presentation reference: `be81d4a5` (latest classic V2). The rebuild stays in the existing fork and branch.

Restored: classic Today/Health/Activity/More navigation, date browsing, Rest/Charge/Effort details, workout export, trends, insights, settings, onboarding, devices, and archive-backed Night Lab. Existing upstream macOS/watch targets are retained. The archive's iPhone-only target deletions were not imported.

Supporting ports include snapshot-based cache reads, startup loading, daily-change comparisons, canonical FIT export, schema 48/49 compatibility, unknown-schema refusal, and WAL/backup safeguards. The live HealthKit sleep uncertainty/overlap transaction from the rebuild remains intact. SleepStager and SleepStagerV2 are unchanged from upstream 12. Auto-workout detector and its default-off preference remain upstream behavior.

## Evidence corrections during integration

- Evidence Lab no longer contains illustrative wear/HR percentages or completed validation assertions. Actual archive inspection remains in Night Lab.
- Stage totals no longer generate a plausible-looking hypnogram. Only recorded segments can supply transition timing; totals remain available as a breakdown.
- Sleep insight links retain their selected date. Recorded-change labels cover both measurements and estimates; imported oxygen readings are not marked experimental.
- Sleep-stage captions do not infer a historical night's algorithm from the currently selected device.
- Charge comparisons use the selected day's preceding records. The current scoring baseline is not presented as a reconstruction of a historical saved score.
- Insight cards label associations beside the comparison. The unvalidated tomorrow-score forecast is replaced by a labelled illustrative model difference.
- The HR banner retains the upstream emitted-value update, avoiding an extra read before Published assigns the new value.

These changes improve presentation fidelity and data handling. They do not demonstrate physiological accuracy, improved sleep, or better sleep-stage classification.

## Verification and limits

The candidate workflow compiles both Apple apps, runs five affected package suites and shared macOS app tests, and runs the restored iPhone UI journeys with synthetic fixtures and screenshot attachments. Results must be checked on the pushed commit; adding checks is not proof they pass. Windows has no local Xcode or Swift toolchain.

At source commit `f1b8e81b`, the iPhone app compiled and all eight simulator journeys passed. Five package suites executed 4,221 tests with two skips and zero failures. Run: https://github.com/Billytheking954/noop-whoop-/actions/runs/42361298601 . That run still failed the macOS compile; the subsequent iPhone-only startup-observer guard addresses its reported error. Later commits require their own CI result. Physical strap behavior and a real-device upgrade/restore remain untested; synthetic regression results do not validate those operations.

Scope is the user's Apple classic interface. Android's presentation and schema remain upstream 12; both schema fixtures now explicitly declare the HealthKit identity tables Apple-only. Schema 48/49 backup interoperability with Android is not validated. Cross-platform backup transfer must not be claimed compatible for the added schema until reviewed and tested. No production scoring algorithm changes are included.

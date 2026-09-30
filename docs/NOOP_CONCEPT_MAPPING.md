# NOOP iPhone concept-to-implementation mapping

Reference sheets: `NOOP Four-Screen Health UI Preview.png`, `NOOP wellness app sample preview.png`, and `NOOP four-screen iPhone sample preview.png` (29 September 2026). These are generated visual concepts, not application captures. Their sample names, readings, dates, device render and notification claims are not release data. This table describes this branch's source paths; runtime and device claims require the hosted build and a physical strap respectively.

Status: **wired** means the current source has a real route and data read; **partial** means some pictured behaviour is absent; **unsupported** means the concept's value/control has no validated source or implementation. A wired row is not a physical-device verification.

| Concept screen / visible element | NOOP source | Action | Status |
| --- | --- | --- | --- |
| Today: Rest ring | `sleep_performance` metric series, `TodayView.restScore` | Opens Rest metric detail | Wired; now first |
| Today: Charge ring | `DailyMetric.recovery`, provenance and baseline | Opens charge breakdown | Wired; now second |
| Today: Effort ring | effective stored/live strain, user scale | Opens strain metric detail | Wired; now third |
| Today: Health snapshot | selected day's resting HR, `HealthView` | Opens Health Monitor | Wired compact first-hop; 5/5 count unsupported |
| Today: Stress summary | `stressToday` and `StressView` | Opens Stress Monitor | Wired day-average or unavailable; sample 1.1 unsupported |
| Today: day review / My Day | existing synthesis, `InsightsHubView` measured changes | Opens Insights hub | Partial; generated narrative in concept unsupported |
| Today: last night's sleep and stages | `DailyMetric.totalSleepMin`, `SleepModel.night.stages` | Opens Sleep | Wired where a session is available |
| Today: overnight HRV and RHR | `DailyMetric.avgHrv`, `restingHr` with carried date | Opens respective metric | Wired |
| Today / Activity: activity card | stored `WorkoutRow`; possible bout from HR detector | Opens detail or review card with Accept, Edit, Dismiss | Partial; only one possible candidate at a time, no multi-candidate history |
| Today: strap / sync | `LiveState` battery and `lastSyncedAt`, local source rows | Expands Data Sources; opens Devices elsewhere | Partial; collapsed footer does not expose every status at a glance |
| Charge: large ring | `DailyMetric.recovery` | Breakdown and metric detail | Wired through Today; pictured dedicated layout partial |
| Charge: HRV / RHR / respiratory / sleep contributors | saved daily rows, charge breakdown and Health | Existing breakdown/details | Partial; no invented arrows or sample baselines |
| Charge: 30-day comparison | stored metric series | Metric Explorer / Trends | Wired route; pictured comparison card partial |
| Health Monitor: HR value and daily chart | live HR and stored HR samples | Health chart and detail | Wired; gaps and timestamps depend on captured data |
| Health Monitor: RHR, HRV, respiration, skin temp | daily row and metric series | Vitals grid and detail | Wired where measured; units/source labels vary by metric |
| Health Monitor: SpO₂ | validated `spo2Pct` only; experimental `spo2_candidate_82` separately gated | Night Lab diagnostics | Partial; candidate is not a production percentage |
| Stress Monitor: dial and daily chart | time-aware `StressDayCurve` / stored HRV evidence | Stress detail and periods | Wired; chart coverage must be checked with offload data |
| Stress Monitor: sleep / run context and time bands | saved sleep/workout windows | Chart context | Partial; concept durations and labels unsupported |
| Sleep: Rest, duration, start/end | `SleepModel` session and `sleep_performance` | Sleep view and night detail | Wired where session exists |
| Sleep: need, stages, consistency, time in bed | sleep model, stage totals and baselines | Existing sleep cards | Wired/partial depending on source coverage |
| Sleep: overnight HRV missing explanation | `DailyMetric.avgHrv` and sleep confidence | Health/Sleep details | Partial; no fabricated HRV |
| Activity: saved workout and HR/zone chart | `WorkoutRow`, stored HR samples | Workout detail/edit/dismiss | Wired for saved rows |
| Activity: possible activity / review | HR detector; optional gravity evidence | Accept, Edit, Dismiss | Wired single candidate; HR alone remains unconfirmed; sport stays generic |
| Trends: date selection and dual axes | daily rows and metric series | Range control, charts, metric details | Partial: pictured exact 7-day dual-axis layout differs |
| Trends: weekly averages / key trends | stored daily rows | Existing digest and metric links | Wired/partial; depends on history |
| Insights: change cards with personal median, dates, source | `DailyChangeInsight` over local daily rows (7 prior values in 30 days), recomputed after sync | Opens measured detail and underlying metric | Partial; local daily row is labelled, original device source needs metric drill-in |
| Insights: notification categories, quiet hours, dedup, exact tap | Local `DailyInsightNotificationScheduler`, stored opt-in and one-per-day decision | Settings control; notification taps route by insight ID | Implemented in source; permission, timing, late-offload withdrawal and tap require hosted/device tests |
| Device: connected strap, sync, battery, firmware | `LiveState`, observed BLE and device registry | Pair, sync, inspect | Wired where observed; sample strap image/name/firmware unsupported |
| Device: broadcast HR toggle | existing `PuffinExperiment` preference and BLE capability gate | Toggle in Devices/Settings | Wired with device checks; physical behavior unverified |
| Settings: appearance, units, Health permissions, sources, export | existing settings and HealthKit/backup paths | Opens actual controls | Wired; pictured compact list differs |
| Settings: notifications and automations | existing reminders/Automations plus local insight settings | Opens category and quiet-hour controls | Partial; runtime permissions unverified |
| Insight Detail: value, recent median, comparison dates and source | `DailyChangeInsight` from local daily records | Opens detail, then metric history | 30-day observed chart with missing-day gaps; exact device-source field still unavailable |
| First Use: strap scan and setup later | `OnboardingWizard` / `AddDeviceWizard`, BLE scan | Pair or defer | Wired; pictured fictional strap/device unsupported |

## Validation boundary

The hosted iPhone simulator build and Swift tests passed for the preceding commit. The source adjustments on this branch require a fresh hosted run. The screenshot workflow uses `--demo-seed` synthetic local data, so its captures demonstrate layout and routes, not a real strap or real physiological readings. A physical WHOOP 5/MG and an appropriately signed, entitled build remain necessary for BLE/offload and HealthKit runtime verification. See `NOOP_SIMULATOR_COMPARISON.md` for the screen-by-screen visual comparison and remaining gaps.

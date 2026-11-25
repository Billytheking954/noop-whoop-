# RyanBr v12 selective integration candidate — 25 November 2026

## Source and scope

Base: `d56a86907aaf5f25aa2e0894f746aed046da616a` on
`rebuild/ryanbr-noop12-selective-battery-20261124` (clean checkout).
Its [selective iPhone workflow run](https://github.com/Billytheking954/noop-whoop-/actions/runs/45496798643)
completed successfully on that exact baseline commit, including iPhone
simulator tests and unsigned IPA packaging. Those results do not test the
new integration commit.
This candidate integrates readiness commit `9e527b257` and the selected
workout review/audit changes from `155dc0f94`, `cf7194ac2` and `89319d6ed`.
It does not merge the checkpoint's older history or restore retired targets.

The base already contains the recent Settings/Today layout and appearance
work (`f17d63e51`), iPhone device/broadcast routing and battery guards
(`07d7a74a9` through `d56a86907`), and storage, migration, HealthKit and
workout completion protections (`bc9910c0f` and descendants).

## Completed in source

- Readiness history now uses calendar-bounded windows, with sparse-history and
  duplicate-pair cache tests. Its physiological thresholds remain unvalidated.
- Opt-in workout suggestions still appear on the actual iPhone Today screens:
  `LiquidTodayView` and `TodayView` both include `AutoWorkoutCard`; Settings
  exposes the default-off toggle through `RootTabView`.
- The card opens a form to review start, end and sport. The existing coarse
  classifier seeds an editable value, including Other/unsure. No workout is
  saved merely by detection.
- The detector suppresses a repeat suggestion when saved intervals overlap or
  lie within its five-minute boundary collar. Local Test Centre audit code
  compares suggested windows with manual/imported labels and reports misses,
  false prompts, duplicates, sport mismatches and processing proxies. The
  extra audit reads occur only with Workouts Test Centre enabled and at most
  once per repository refresh sequence.
- Reviewed saves check the **edited** interval across all workout owners in
  the same database write transaction. Duplicate/overlapping rows are rejected;
  database errors propagate to the card, and dismissal occurs only after a
  successful write. Store tests cover an overlapping import and concurrent
  reviewed writes.
- The new UI messages have catalogue entries for the shipped localisations.

## Compatibility and safety

`project.yml` increments only `CURRENT_PROJECT_VERSION` from 438 to 439;
`Config/BundleId.xcconfig`, entitlements, BLE pairing commands, schema
migrations, and HealthKit writeback code have not been changed. The configured unsigned iPhone identity is
`com.noopapp.noop`, widget `com.noopapp.noop.widgets`, and shared app group
`group.com.noopapp.noop.staging`; build 439 follows the documented original
v12 identity. These source settings do **not** establish that a separately
signed SideStore install will update in place or preserve actual user data.

## Verification and remaining work

The full selective iPhone CI workflow must complete on this exact commit:
Swift packages, Python tooling, localisation, macOS compilation/tests,
iPhone simulator tests and launch, unsigned device compilation and IPA
identity checks. Inspect the macOS test log because a hosted Metal abort can
leave that job successful without executing XCTest. Linux cannot run Xcode or
physical strap tests. No real labelled workouts, battery measurements, signed
in-place update, existing health database or WHOOP pairing were available to
validate; the audit's synthetic tests are not accuracy evidence. The candidate
must remain experimental and is **not** a release declaration.

## Incomplete / blocked / unverified

- **Incomplete:** The existing detector still uses a provisional five-minute
  merge policy and has no validated real-session evidence for long HR sample
  gaps or genuine rests. This integration does not promote its thresholds or
  make the experimental suggestion toggle automatic.
- **Blocked locally:** This Linux runner has no Xcode or Swift toolchain; the
  iPhone and macOS build/test gates require the selected GitHub macOS runners.
- **Unverified:** There is no signed update onto the installed RyanBr app, no
  existing-device database or pairing probe, no actual receiver/strap test, and
  no labelled-session or battery-cost measurement for this candidate.

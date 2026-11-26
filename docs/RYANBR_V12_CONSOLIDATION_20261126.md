# RyanBr v12 integration candidate — 26 November 2026

## Source and selected changes

This branch descends from `d56a86907aaf5f25aa2e0894f746aed046da616a`, the requested
selective battery baseline. The single integration commit `52cbceb5b047ff5315435f9ca4372c086ea0c46e`
selectively imports readiness and opt-in workout review from their divergent branches. The
earlier Settings, Today, appearance, battery, broadcast, storage and HealthKit work is already
in the baseline. See `RYANBR_V12_CANDIDATE_20261125.md` for its detailed inventory. No other
divergent branch has been merged wholesale.

## Completed in this follow-up

- Independent adversarial review found that sparse elevated HR samples could span an hour and
  become a false workout, and that a measured three-minute rest could be merged into one
  activity. The Swift detector and its diagnostic trace now stop across an HR sample gap longer
  than 120 seconds and retain separate bouts across measured rest. Kotlin and its trace use the
  same rules, with mirrored regression cases. The threshold is a conservative provisional
  safeguard, not a measured optimal value.
- The iPhone suggestion scan now reads only workouts overlapping its HR window, including a
  workout that began before the scan. It avoids loading years of display history and resampling
  every stored workout on each Today refresh. Reviewed saves still check overlaps atomically
  across all workout owners before inserting.
- The selective GitHub workflow now also compiles and tests the Android twin, in addition to
  Swift packages, Python tools, macOS, iPhone simulator and unsigned IPA identity checks.
- Both iPhone Today implementations mount the same suggestion card; the default iPhone tab uses
  `LiquidTodayView`. The default-off Settings switch gates the entire detector. The card opens
  an editable start/end/sport form; detection alone never persists a workout.

## Identity and data boundary

No bundle prefix, iPhone/widget identifiers, app group, BLE pairing command, database
migration or HealthKit writeback path is changed by this follow-up. The unsigned build is
configured for `com.noopapp.noop`, widget `com.noopapp.noop.widgets`, and
`group.com.noopapp.noop.staging`. Source configuration and simulator reinstall tests cannot
prove that SideStore will retain the signed installed app's entitlements, database or pairing.
The workflow compares packaged identity against upstream v12 if its release IPA is available.

## Status and verification

- **Completed in source:** The selected integration, sparse-HR/rest safeguards, bounded
  overlap read and parity regression cases. The feature remains opt-in and offline.
- **Blocked locally:** This Linux environment has no Xcode/Swift toolchain or cached Gradle
  distribution. The GitHub workflow is the build and test gate; its results must be checked on
  this branch's exact head before declaring any CI result.
- **Unverified:** Physical WHOOP pairing and receiver tests, actual signed SideStore in-place
  upgrade, retained health data on that device, labelled real-session accuracy, false prompt
  rates, long-rest sensitivity and measured battery cost. The local audit's synthetic fixtures
  do not establish clinical or sport-classification accuracy.
- **Incomplete:** Detector thresholds and sport classification need real labelled sessions;
  a true release decision needs physical device and data-retention evidence. No automatic
  workout capture is promoted by this branch.

This is a candidate for verification, not a release-ready declaration or a physical-device
validation claim.

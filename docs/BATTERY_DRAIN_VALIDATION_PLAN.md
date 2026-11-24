# Measure and reduce iPhone and strap battery drain by usage mode

## Goal

Measure and reduce battery drain separately for the iPhone and the connected strap, without weakening sync or health-data reliability.

This work must produce comparable physical-device evidence. A successful compile, a passing test, or changing a setting is not evidence of a battery improvement.

## Scope

Establish separate baselines for both **iPhone battery drain** and **strap battery drain** in these modes:

1. Idle use
2. Normal background sync
3. Live monitoring
4. Workout use
5. Phone HR rebroadcast
6. Direct strap HR broadcast

Inspect the largest contributors in each mode, including:

- BLE disconnect/reconnect count, reason and time spent reconnecting
- connection/bond churn and repeated characteristic discovery/subscription
- history-sync frequency, duration, rows/bytes persisted and empty syncs
- background task starts, duration, CPU time, expirations and retries
- continuous HRV duty cycle, including overnight-only behavior
- live/workout timers and screen-on work
- phone HR rebroadcast and direct strap broadcast lifecycles
- battery polling and other periodic BLE commands
- the existing Power saving, Pause HRV capture, Low refresh and iOS Low Power Mode interactions

## Test protocol

Use the same physical iPhone, strap, firmware, NOOP build, iOS version and test settings for before/after comparisons.

Record at minimum:

- iPhone model, iOS version, battery health, starting/ending charge and elapsed time
- strap family/model, firmware, starting/ending charge, charging state and elapsed time
- app foreground/background time
- screen-on time and brightness policy
- Wi-Fi/cellular/Bluetooth state, signal conditions and Low Power Mode
- Power saving threshold, Pause HRV capture, Low refresh and Continuous HRV/overnight-only settings
- reconnect count and attributed disconnect reasons
- sync attempts/completions, empty syncs, duration, persisted rows/bytes and failures
- MetricKit CPU/background/disk-write values when available
- health-write attempts, successes, failures and resulting sample counts

Run before and after under the same conditions. Use a long enough window to overcome coarse battery percentages, and repeat each scenario enough to report the spread rather than a single favorable run. Do not compare different strap firmware, phone settings, screen use, radio conditions or Continuous HRV settings as if they were equivalent.

For each mode, report separate rates:

- iPhone: percentage points per hour, with the range across repeats
- strap: percentage points per hour, with the range across repeats

If iOS or strap percentage resolution makes a run inconclusive, label it inconclusive and lengthen or repeat the run.

## Measurement support

Add local-only, bounded diagnostic output where current logs cannot attribute cost. Prefer session summaries over per-packet logging. A report should make it possible to correlate:

- mode transitions
- connection and reconnect lifecycle
- continuous-HRV stream armed time
- live/workout/rebroadcast active time
- sync work and empty polls
- background execution and expiration
- phone and strap battery samples

Diagnostics must remain on-device and manually exported, with no analytics or server dependency.

### Instrumentation audit (2026-11-24)

| Evidence | Current support | Remaining gap |
|---|---|---|
| Strap charge | Battery Test Centre mode banks bounded, tagged SoC samples and fits a gated discharge slope. | Physical run start/end charge and charging interruptions still require the run sheet. |
| iPhone cost | MetricKit records daily foreground/background time, CPU, peak memory, logical writes, hangs and exits in the local strap log. | MetricKit is delayed and aggregate; the tester must record phone start/end charge for each run. |
| Connection | The connection log records attributed disconnects, link duration, inbound frames/bytes and reconnect evidence. | A single per-run reconnect summary is not yet emitted. |
| History sync | Backfill logs record starts, end reasons, elapsed time, decoded/persisted rows and repeated empty outcomes. | Bytes written and a per-run attempts/completions/empty summary are not yet emitted. |
| Continuous HRV | Preference reconciliation and overnight-window open/close transitions are logged. | Armed duration is not yet summarized per run. |
| Live/workout/broadcast | Workout and phone/direct-broadcast lifecycles each have local event lines. | Active duration is not yet summarized per run. |
| Background work | MetricKit reports aggregate background time and background-task timeout exits. | Individual background-task start, duration, expiration and retry totals are not yet summarized. |
| Reliability | Sync persistence, Health sync wake/sync/coalescing totals and HealthKit failures are locally diagnosable. | Each run still needs an explicit expected-versus-observed reliability result. |

The first implementation increment adds a reusable run sheet and exposes the Battery registry's fixed
configuration questions in the Apple Test Centre. Answers stay on-device and are included in `meta.json`
when the tester manually shares a bundle. This closes the configuration-attribution gap without adding a
timer, per-packet logging, analytics or BLE behavior.

Use [`BATTERY_DRAIN_RUN_SHEET.md`](BATTERY_DRAIN_RUN_SHEET.md) for every before/after run. Do not combine
modes or repeat numbers in one row.

## Fix order

1. Complete the baseline matrix.
2. Rank causes by measured contribution to phone drain, strap drain and reliability cost.
3. Fix the largest attributable cause first.
4. Re-run the same scenario and settings.
5. Continue in descending measured impact.

Avoid broad cadence changes before attribution. Preserve the existing BLE safety contract and do not add destructive strap commands.

## Reliability gates

Battery work must not regress:

- automatic reconnect after ordinary link loss
- manual sync and normal periodic sync
- history completeness and duplicate handling
- live heart rate
- workout recording
- continuous or overnight HRV behavior
- phone HR rebroadcast
- direct strap HR broadcast
- HealthKit write success, deduplication and sample completeness
- background and foreground transitions

Compare expected source data with persisted rows and HealthKit results for each before/after run. Record missing, delayed, duplicated or failed data explicitly.

## Deliverables

- [x] Reproducible test matrix and fixed configuration sheet
- [ ] Separate before baselines for iPhone and strap in all six modes
- [ ] Attributed reconnect, background, sync and Continuous HRV evidence
- [ ] Ranked list of measured causes
- [ ] Targeted fixes for the largest causes
- [ ] Same-settings after measurements with repeated runs
- [ ] Sync and health-data reliability comparison
- [ ] Raw or redacted diagnostic bundles, or summarized evidence, attached
- [ ] Release notes that state only measured results and their exact conditions

## Acceptance criteria

- Every claimed improvement has before and after physical-device measurements under the same settings.
- Phone and strap results are reported separately.
- All six usage modes have a baseline, or are explicitly marked blocked or inconclusive with the reason.
- The largest measured cause is addressed before lower-impact tuning.
- Reconnect, sync, HR and HRV, workout, rebroadcast and HealthKit reliability checks pass.
- No battery improvement is claimed from compile success, unit tests, a code diff or a setting change alone.

## Handoff for implementation chats

Work on the `battery-baseline-and-drain-fixes` branch and keep this document updated with the measurement configuration, raw run summaries, ranked causes, commits and verification status. Push implementation commits to the same branch so the draft pull request remains the shared source of truth.

Start by auditing the existing controls and diagnostics in:

- `Strand/Screens/PowerSavingView.swift`
- `Strand/BLE/BLEManager.swift`
- `Strand/BLE/BackfillPolicy.swift`
- `Strand/System/BatteryGuidedCapture.swift`
- `Strand/System/MetricKitLine.swift`
- `StrandiOS/System/MetricKitLog.swift`

The repository's `AGENTS.md` and BLE safety contract remain authoritative. App-target changes require an actual iPhone build, and BLE behavior requires real-strap validation. If physical hardware is unavailable, limit work to measurement support and tests, mark hardware steps pending, and do not claim a battery improvement.

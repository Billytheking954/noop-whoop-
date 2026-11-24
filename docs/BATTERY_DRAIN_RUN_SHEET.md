# Battery drain run sheet

Use one copy of this sheet for each physical-device run. Keep the phone, strap, firmware, build, radios,
screen policy and power settings identical between a mode's before and after runs. Save the matching Test
Centre bundle with the run. A compile, test pass or setting change is not a battery result.

## Run identity

| Field | Value |
|---|---|
| Run ID | `<mode>-<before-or-after>-<repeat>-<date>` |
| Usage mode | Idle / normal background sync / live monitoring / workout / phone HR rebroadcast / direct strap HR broadcast |
| Comparison phase | Before baseline / after change |
| Repeat number | |
| NOOP commit and build | |
| Change under test (after only) | |
| Start and end time, including time zone | |
| Elapsed hours | |
| Result status | Valid / inconclusive / blocked |
| Inconclusive or blocked reason | |

## Fixed configuration

| Field | Value |
|---|---|
| iPhone model and iOS version | |
| iPhone battery health | |
| Strap family/model and firmware | |
| Official WHOOP app installed/running | |
| Other paired phone or BLE client | |
| Wi-Fi, cellular and Bluetooth state | |
| Radio/signal conditions | |
| iOS Low Power Mode | |
| Screen-on time and brightness policy | |
| NOOP foreground/background time | |
| Power saving enabled and threshold | |
| Pause HRV capture | |
| Low refresh | |
| Continuous HRV and overnight-only | |
| Charging during run | None / describe interruption |
| Other battery-saver apps or automation | |

## Battery observations

Record percentage points, not relative percent change.

| Device | Start charge | End charge | Drop (percentage points) | Rate (points/hour) |
|---|---:|---:|---:|---:|
| iPhone | | | `start - end` | `drop / elapsed hours` |
| Strap | | | `start - end` | `drop / elapsed hours` |

If either percentage does not move, do not report a zero-drain conclusion from a short run. Mark the run
inconclusive and lengthen or repeat it.

## Attributed activity

| Evidence | Result |
|---|---|
| Connects and involuntary reconnects, with reasons | |
| Time spent connected/reconnecting | |
| Sync attempts/completions/failures/empty syncs | |
| Sync duration, persisted rows and bytes when available | |
| Continuous-HRV armed time | |
| Live/workout/rebroadcast active time | |
| Background task starts/duration/expirations/retries | |
| MetricKit foreground/background/CPU/disk values | |
| Phone and strap battery sample count | |

## Reliability gates

| Gate | Expected | Observed | Pass / fail / not exercised |
|---|---|---|---|
| Automatic reconnect after ordinary loss | | | |
| Manual and periodic history sync | | | |
| History completeness and duplicate handling | | | |
| Live heart rate | | | |
| Workout recording | | | |
| Continuous or overnight HRV | | | |
| Phone HR rebroadcast | | | |
| Direct strap HR broadcast | | | |
| HealthKit attempts, successes, failures and sample count | | | |
| Foreground/background transitions | | | |

## Six-mode comparison matrix

Enter the range across valid repeats, not only the most favorable run. Keep iPhone and strap results
separate. Link each cell to its run sheet and redacted Test Centre bundle.

| Mode | Before iPhone points/hour | After iPhone points/hour | Before strap points/hour | After strap points/hour | Repeats | Reliability | Evidence link |
|---|---:|---:|---:|---:|---:|---|---|
| Idle use | | | | | | | |
| Normal background sync | | | | | | | |
| Live monitoring | | | | | | | |
| Workout use | | | | | | | |
| Phone HR rebroadcast | | | | | | | |
| Direct strap HR broadcast | | | | | | | |

## Interpretation

- Rank causes only after matched baselines exist.
- State the exact mode, settings, hardware, firmware, elapsed time, repeat count and observed range.
- Do not claim improvement when before and after ranges overlap without enough evidence to distinguish them.
- Record missing, delayed, duplicate or failed data even when battery drain improves.
- Keep raw bundles local or redact them before attaching them to a public issue or pull request.

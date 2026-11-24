# Activity detection and day load: current iPhone path

The iPhone collector banks timestamped heart-rate samples from live BLE and historical offload in
`WhoopStore`. It also stores gravity samples when the device supplies decodable motion. The repository
unions the active strap and canonical history by timestamp, giving the active strap precedence. A sync
bumps the Today refresh sequence; the activity card then scans the previous two days. A manual check
re-reads the stored stream, but does not initiate BLE offload.

The published suggestion detector requires heart rate at least 30 bpm above the available nightly
resting value for at least 12 minutes. It tolerates brief measured dips and merges nearby observed
bouts. It now closes a bout across an HR gap over two minutes and does not merge through that gap.
Saved workouts of any source suppress a candidate that overlaps or sits within a five-minute boundary
collar. Durable dismissals use the same boundary-tolerant rule, so late samples cannot move an inferred
start or end enough to repeat a prompt the user already handled. The save path re-reads saved workouts
immediately before writing, covering an Apple Health import that arrives while review is open.

The card offers one candidate at a time. It may seed the review form with the existing broad heuristic's
**suggested** class (Walking, Running, Strength, Cycling, Skiing, or Other / unsure), but never states the
sport as fact and never overwrites a user choice. There is no one-tap save: the user reviews and may edit
both timestamps and sport before explicitly saving through the manual workout path. Other remains a
first-class choice for weak or unsupported evidence.
Movement evidence is reported separately when there are enough closely spaced gravity records. An
HR-only pattern remains a **possible activity**, not a confirmed workout or a sport classification.
Static exercise, cycling, sparse WHOOP 5/MG gravity, and offloaded data can all limit that evidence.

The daily Effort score already integrates the whole local calendar day's HR with `StrainScorer`.
`AnalyticsEngine.analyzeDay` uses `dayHr`; Today also recomputes from local midnight to now when
enough data has arrived. Per-sample duration is capped at two minutes across missing HR. The default
Edwards method counts sustained cardiovascular load at 50% heart-rate reserve or higher, so some
ordinary movement scores zero. An optional Banister method counts lighter work above its sedentary
floor. Both are NOOP estimates on a 0–100 scale. The Stress screen separately shows an approximate
hourly autonomic-load timeline and masks substantially ambulatory hours when motion is available.
Adding its score to Effort would count part of the same HR elevation twice; this change does not do so.

## Still to implement and validate

- A minute-level Effort timeline with explicit missing-data intervals, using the same TRIMP recipe and
  showing a final value that reconciles with the day score. The current UI shows the daily total.
- A persisted activity-candidate list with multiple suggestions and split/merge actions. The existing
  path reviews one candidate at a time.
- A device replay proving WHOOP 5/MG history availability, HR/motion coverage and delayed sync timing;
  iOS background execution and HealthKit dedup need device validation.
- The Android twin is not included in this fork checkout, so the new HR-gap rule cannot claim
  cross-platform parity yet.

## Real-label audit and cost reporting

With **Test Centre → Workouts & GPS** active, the same two-day local scan evaluates the published
detector without saved-workout suppression against real manual/imported workout labels. Detector-created
history is excluded from ground truth. Stable local trace rows report, by broad activity, labelled and
matched sessions, missed sessions, unmatched false prompts, duplicate detections and classifier sport
mistakes. Unsupported labels map to `other`; a specific guess for one counts as a mistake instead of
being treated as knowledge.

The audit also records wall-clock processing time, HR/gravity/step row counts and an explicitly
approximate payload-byte floor. Its battery boundary is stated rather than guessed: it adds zero BLE
reads and zero sensor sampling seconds because it reads only already-stored rows; iOS exposes no
trustworthy per-operation battery-energy counter, so direct battery energy is reported as `n/a`. No
audit row leaves the device unless the user explicitly exports a Test Centre report.

No sleep, recovery, or SpO2 scoring rule changed here. The activity suggestion's resting-HR fallback
is 60 bpm when no nightly value exists, which may miss or over-suggest activities for some users.

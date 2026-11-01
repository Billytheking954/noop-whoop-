# Simulator stabilisation evidence

`app-build.yml` checks out the exact PR head. The existing `NOOPiOS` scheme runs
the hosted app suite and UI journeys. It then creates an iPhone 13 mini simulator
and captures the existing screen routes in light/dark modes and accessibility text.
The extended validation refuses to call another device a mini.

The opt-in DEBUG simulator arguments `--demo-seed --simulator-validation` extend
the existing seed to 400 days, covering the recent 120-day cache and older history.
The PRNG and local-day noon reference make a given day's fixture reproducible.
No `--demo-hour` presentation overrides are used. Normal demo seeding remains 120
days. No simulator is erased and no application database is reset. Use disposable
CI simulators; these arguments are not intended for personal health stores.

`SimulatorStabilisationTests` checks deterministic rows/workouts, replay deduplication,
an interrupted SQLite writer transaction, a second file-store pool, integrity,
recent-to-full-history publication and cancellation of a shared refresh waiter.
Existing suites separately cover generation invalidation, source changes, read
failures, consistent snapshots, cross-source workout deduplication, v49 and WAL backup.
An injected transaction error is not an OS power-loss test.

The UI checks observe actual selected-day/rest/charge state via a DEBUG-only calendar
accessibility value. They exercise repeated process launches, rapid date gestures,
scrolling, navigation and a year-old date. Screenshots are retained in xcresult
attachments for visual inspection; coordinate assertions alone do not prove all text
is unclipped or every card is correct. The year-old entry argument selects a real
stored date; it does not replace score values. The normal calendar-opening test is
also retained.

`Tools/simulator_stabilisation.py` captures six repeated process-cold launches on
an already seeded simulator. Each record must match the launched PID, contain at
least 120 cached days and complete Today calculations. It retains individual phase
durations, min/median/max and population standard deviation. These intervals begin
at `ColdLaunchTrace.begin`, not the OS launch boundary. XCTest separately records
time until populated score state is observed, including launch/idle automation cost.
Neither timer measures first pixel paint. Filesystem/OS caches remain warm between
process launches; the initial seed creation is excluded from repeat samples.

The simulator has no physical strap or fresh import. Cached operation is exercised
without those data sources, while host networking remains enabled. This does not
prove behavior under an OS-enforced loss of all network routes. No real BLE,
battery, thermal, physical iPhone latency, installation, background reconnection,
HealthKit permissions/deletion semantics or physiological accuracy is established.
Those remain physical-device gates. Production calculations, schema v49, WAL
backup primitives and WHOOP connectivity implementations are unchanged.

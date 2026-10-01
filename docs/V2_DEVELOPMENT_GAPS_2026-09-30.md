# NOOP V2 development gaps — 30 September 2026

## Reviewed source and integration

Main remains c064b3e834dc44d560b82e132d4cce1db287fe29. The concept UI advanced during this
audit to 344c745a53ace2d112918e587ccb9e21dbc3e98a; this integration preserves that latest tree.
HealthKit source and dependencies are reused from #25–27 at
31f400af6af659bab568596d9099d634f67e759c. Reuse does not mean those PRs were merged.

## Fixed gaps

- Genuine SDNN is required for Apple Health HRV; RMSSD is no longer a fallback.
- Local source reads complete before any writeback deletion. Read failures propagate.
- Prior keyed sleep, vitals, HR and workouts are captured, replacements save, then captured
  old objects retire. Legacy retirement is metadata-scoped and occurs after replacement success.
- Legacy FIT hiking export uses sport 17; sport 15 imports as rowing. The matching former
  decoder mistake concealed the exporter error in round-trip tests. New coverage inspects
  the raw session enum and imports a valid sport-15 fixture.
- Unsigned development provenance records the HealthKit contributions and exact integration
  source SHAs. The formal release freeze remains unchanged.
- AGENTS.md now distinguishes current iPhone fork/CI instructions from historical upstream guidance.

FIT enum reference: https://github.com/garmin/fit-python-sdk/blob/main/garmin_fit_sdk/profile.py

## Remaining gaps

| Gap | Required next work |
| --- | --- |
| Physical WHOOP/iPhone behavior | Record pairing, reconnect, overnight capture, delayed history offload and background tests. |
| HealthKit runtime | Verify denied read access, OS save/delete failures and workout child-sample retirement on an entitled device. Save-before-retire preserves old data on save failure but is not atomic; deletion failure can leave duplicates. |
| Activity candidates | Persist multiple candidates with evidence/confidence and edit/split/merge. Current UI offers one possible activity at a time; HR cannot establish sport. |
| Minute-level Effort | Show missing intervals and reconcile the timeline with the existing whole-day score. |
| Insight alerts | Controls/routing exist, but foreground/offload reconciliation is not continuous background monitoring. Test permissions, quiet hours, late data and cold-start taps. |
| Concept UI | Several Charge, Trends, source-detail and context treatments remain partial; see NOOP_CONCEPT_MAPPING.md and NOOP_SIMULATOR_COMPARISON.md. |
| SpO2 evidence | Candidate identity and independent nightly agreement remain unverified. Keep research isolated. |
| Signed final release | Resolve the frozen manifest's stale live-open-PR classification through explicit release scope review, then signing and exact-source verification. |

## Validation boundary

The combined tree requires its own CI; earlier passing branch runs do not validate this integration.
Before session interruption, retained Python tool tests (30), iPhone-only invariants, localisation,
source hygiene and diff checks passed on the local integration. The capture suite was started but
its completed result was not recovered. Swift/Xcode and physical-device validation were not run
locally. The pull request records current hosted check status.

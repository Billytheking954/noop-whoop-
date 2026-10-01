# NOOP iPhone concept comparison

The three supplied sheets are generated visual references. The screenshots named below were captured from a running iPhone simulator at 1080 × 2340 in dark appearance with `--demo-seed` local synthetic data. They prove rendering and navigation, not physiological accuracy or WHOOP 5.0 hardware behavior. The comparison reflects the latest reviewed captures; layout changes after those captures need a fresh screenshot run before release.

| Concept screen | Actual capture | Implemented relationship | Material difference or validation limit |
| --- | --- | --- | --- |
| Today | `today-dark.png` | Rest, Charge, Effort ring row; Health, Stress, sleep, activities, insights and source status link to details | The actual feed has more text and vertical space; the device state is observed, not the illustrated strap. |
| Charge | `chargebreakdown-dark.png` | Saved recovery score, contributors and trend detail | The dedicated page uses an existing breakdown rather than the concept's large hero ring and comparison geometry. |
| Health Monitor | `health-dark.png` | Live HR trace, saved vital tiles, sync state and full-day timeline route | The captured state is offline, so no live heart-rate value exists. The sync control and age estimates differ from the concept. The full-day saved-HR chart is a separate route. |
| Stress Monitor | `stress-dark.png` | Current supported stress proxy, markers, intraday timeline when samples exist, trend and method | The captured feed's chart sits lower; absent intraday samples must stay absent. Activity and sleep context is less detailed than pictured. |
| Sleep | `sleep-dark.png` | Saved session, Rest, duration, stages, need and confidence in existing details | Scenic score hero and night marks occupy more space; the concept's compact stage-first arrangement is not matched. |
| Activity | `workouts-dark.png` | Saved workout detail and possible-activity review with persistent accept, edit and dismiss | Earlier capture prioritizes effort summary; latest source moves saved sessions above it and adds review to Activity. A candidate is only a suggestion, with generic sport. |
| Trends | `trends-dark.png` | Range control, labelled metric charts and metric links; weekly digest supports date browsing | Earlier capture starts with a digest; latest source places charts first. The concept's exact seven-day dual-axis chart is unsupported. |
| Insights | `insightshub-dark.png` | Local measured-change history, personal comparison, dates and detail routes | Cards were taller in the captured version; latest source tightens them. Sample prose and values are unsupported. |
| Device | `devices-dark.png` | Real discovered device, pairing, sync and battery state where observed | No illustrated strap render or fictional firmware; a physical strap is needed to verify BLE/offload. |
| Settings | `settings-dark.png` | Appearance, units, sources, permissions, export and insight alert preferences | Existing settings hierarchy is longer than the concept's condensed grouping. HealthKit entitlements need a signed device build. |
| Insight Detail | `insightdetail-dark.png` | Exact measured value, personal median, window, source and metric link | No concept-style 30-day mini chart or original-device source field. |
| First Use | No first-use capture; `addwizard-dark.png` covers pairing | Pairing and defer routes use actual scanning states | The pictured fictional strap cannot be shown as an observed device; the full onboarding screen remains visually unverified. |

The source-to-action status for individual visible elements is in `NOOP_CONCEPT_MAPPING.md`. Once a fresh simulator run finishes, compare its captures to these rows and update any changed observations.

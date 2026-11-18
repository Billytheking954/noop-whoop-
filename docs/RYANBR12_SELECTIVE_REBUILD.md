# Ryanbr v12 selective rebuild | decision record

**Date:** 16 November 2026

**Upstream foundation:** ryanbr/noop tag v12.0.0, commit `7acce06c3d22cb5dfe959f2c4a43902471d21332`.

## Direction and constraints
The iPhone app should use Ryanbr's existing NOOP 12 Liquid Metal UI, navigation and detailed native metrics. This branch is isolated; the existing main and the earlier November rebuild branch remain untouched. Do not merge without owner approval.

Selective additions are backend-first and do not replace the upstream schema, BLE controller, HealthKit write paths, backup pipeline, or actual stored user data. A test passing against generated data is not a real-device certification.

## Port decisions
1. **Training readiness**: selectively port the confidence/driver-rich readiness calculations and regression tests from `feature/noop-v2-enhanced-phase3-health-20261025`. Numeric scores are estimates, not verified physiological measurements. The existing Ryanbr Charge breakdown now shows the estimate and available evidence; no second competing readiness system has been introduced.
2. **Energy Reserve**: port the original deterministic, offline-only estimator and tests from the same branch. It emits only observed wake/workout/current checkpoints and does not manufacture a continuous measurement history. An explicitly experimental daily read now appears inside the existing Charge breakdown sheet. It has no invented workout timeline.
3. **SpO2**: keep Ryanbr's existing measured/raw SpO2 pipeline. Port the custom research-only 0x52 hypothetical summary-frame decoder/quality filter/aggregate, plus its regression tests, WITHOUT connecting it to production metrics or HealthKit. Frame structural tests do not establish device identity, optical calibration, or clinical accuracy.
4. **Workouts**: port loss-aware canonical workout identity, data-source provenance, deterministic FIT serializer and associated tests. Never fabricate GPS, HR samples, lap timestamps or missing records. The native upstream Workout Detail screen now has a measured-record FIT export action, with no invented samples. Recorded GPS point GPX now retains original millisecond timestamps, while legacy polyline-only GPX is expressly labelled approximate.
5. **Interface**: deliberately do NOT port the old V2 classic tabs, alternate theme/components, navigation changes, or the prior rebuild's UI restoration. Maintain Ryanbr 12's layout.

## Verification and release gates
- All five Swift package suites, macOS hosted tests, iPhone simulator build/install/launch screenshot (smoke test, not an automated UI assertion) and a Release arm64 iPhone device build.
- IPA preflight: ZIP CRC, duplicate entries, app + widget executables, matching app/widget versions and App Group, embedded exact Git SHA, absence of Watch payload, ad-hoc entitlements, SHA256 sidecar.
- No claim about real WHOOP capture, battery usage, device pairing, restoration of an existing phone's SQLite/WAL database, or clinical SpO2 correctness until tested on a physical device.
- Use a side-by-side test bundle ID so this unsigned candidate cannot silently overwrite a live data store. Do not delete/reset the installed app.

A future **in-place migration** requires an independently verified complete database backup (including committed WAL), documented schema compatibility and HealthKit/WHOOP pairing checks, then a controlled physical iPhone test. A GitHub Actions IPA artifact is not production approval.

## Audit evidence
Previous `rebuild/ryanbr-noop12-20261105` was rooted in Ryanbr v12 and all package compile/test jobs succeeded at `f29a52d`, but its iPhone interface job failed. It also intentionally restored the old V2 screens, which is now outside the requested scope. Prior old-fork draft PRs remain unmerged.

No user records or paired device were accessed while preparing this isolated source branch.

## Follow-up correctness fixes and implementation
- Daily training load requires 28 consecutive real calendar-day values for an acute:chronic ratio, instead of compressing missing days into a false 28-day window. A recorded zero-strain rest day is valid; gaps are not. Separate regression tests cover both.
- The readiness sheet was updated for the extra score fields and the new `.value` evidence case, preserving the original Ryanbr layout.
- FIT export uses the originating strap for detected workouts and the local strap stream for manual workouts. Imported workouts omit timed heart-rate samples when a source-owned stream is unavailable. Actual GPS timestamps come from the separately stored per-workout `RoutePointStore` and are required before including a route in FIT.
- Shortcuts previously inspected the lightweight route map, which intentionally excludes the measured point arrays, causing false `noExportableRoute`. The lookup now reads the sidecar points and FIT uses the canonical timestamped encoder. Recorded GPX now preserves actual millisecond fix timestamps; interpolation remains only for legacy polyline-only routes and is explicitly labelled approximate.
- Ryanbr v12 originally supplied no iOS test action. Build 436 adds an iPhone-hosted safety test target and scheme action; CI now requires those tests as well as the macOS hosted and package tests before IPA packaging. The launch screenshot remains a separate smoke check.
- The unsigned staging IPA workflow runs against the exact committed SHA, requires a re-signing sideloader, preserves a separate bundle identity, checks the app/widget archive, and records SHA256. GitHub runners must actually execute before an artifact is claimed.

- The measured GPX export is available from the native workout screen and from Shortcuts when real timestamps were saved. New regression tests pin irregular millisecond intervals and reject invalid, reordered points rather than laundering them into a believable track.

## Staging maintenance checks

- Liquid Today binds readiness and Energy Reserve estimates to the selected local day. The logical day rolls at 04:00 local time across daylight-saving transitions.
- Live GPS distance updates incrementally. The newest-route Shortcut checks recent routes first, and native export scratch files are isolated and cleared after sharing.
- The selective readiness additions target Apple. Android still uses the upstream readiness engine and can return different load and readiness assessments.
- Build 436 adds a validated, versioned route payload to backups, including recorded fixes from preferences, and preserves a route recovery copy alongside the rollback database. The store retains at most 400 routes. Interrupted database/preferences replacement still needs fault-injection and physical-device validation before in-place migration.

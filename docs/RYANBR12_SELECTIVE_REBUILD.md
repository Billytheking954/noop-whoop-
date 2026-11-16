# Ryanbr v12 selective rebuild | decision record

**Date:** 16 November 2026  
**Upstream foundation:** ryanbr/noop tag v12.0.0, commit `7acce06c3d22cb5dfe959f2c4a43902471d21332`.

## Direction and constraints
The iPhone app should use Ryanbr's existing NOOP 12 Liquid Metal UI, navigation and detailed native metrics. This branch is isolated; the existing main and the earlier November rebuild branch remain untouched. Do not merge without owner approval.

Selective additions are backend-first and do not replace the upstream schema, BLE controller, HealthKit write paths, backup pipeline, or actual stored user data. A test passing against generated data is not a real-device certification.

## Port decisions
1. **Training readiness**: selectively port the confidence/driver-rich readiness calculations and regression tests from `feature/noop-v2-enhanced-phase3-health-20261025`. Numeric scores are estimates, not verified physiological measurements. Avoid a second competing readiness model.
2. **Energy Reserve**: port the original deterministic, offline-only estimator and tests from the same branch. It emits only observed wake/workout/current checkpoints and does not manufacture a continuous measurement history. This backend does not automatically make a new user-facing screen.
3. **SpO2**: keep Ryanbr's existing measured/raw SpO2 pipeline. Port the custom research-only 0x52 hypothetical summary-frame decoder/quality filter/aggregate, plus its regression tests, WITHOUT connecting it to production metrics or HealthKit. Frame structural tests do not establish device identity, optical calibration, or clinical accuracy.
4. **Workouts**: port loss-aware canonical workout identity, data-source provenance, deterministic FIT serializer and associated tests. Never fabricate GPS, HR samples, lap timestamps or missing records. The backend does not automatically enable an export button in the upstream UI.
5. **Interface**: deliberately do NOT port the old V2 classic tabs, alternate theme/components, navigation changes, or the prior rebuild's UI restoration. Maintain Ryanbr 12's layout.

## Verification and release gates
- All five Swift package suites, macOS hosted tests, iOS simulator tests/screenshot attachments and a Release arm64 iPhone device build.
- IPA preflight: ZIP CRC, duplicate entries, app + widget executables, matching app/widget versions and App Group, embedded exact Git SHA, absence of Watch payload, ad-hoc entitlements, SHA256 sidecar.
- No claim about real WHOOP capture, battery usage, device pairing, restoration of an existing phone's SQLite/WAL database, or clinical SpO2 correctness until tested on a physical device.
- Use a side-by-side test bundle ID so this unsigned candidate cannot silently overwrite a live data store. Do not delete/reset the installed app.

A future **in-place migration** requires an independently verified complete database backup (including committed WAL), documented schema compatibility and HealthKit/WHOOP pairing checks, then a controlled physical iPhone test. A GitHub Actions IPA artifact is not production approval.

## Audit evidence
Previous `rebuild/ryanbr-noop12-20261105` was rooted in Ryanbr v12 and all package compile/test jobs succeeded at `f29a52d`, but its iPhone interface job failed. It also intentionally restored the old V2 screens, which is now outside the requested scope. Prior old-fork draft PRs remain unmerged.

No user records or paired device were accessed while preparing this isolated source branch.

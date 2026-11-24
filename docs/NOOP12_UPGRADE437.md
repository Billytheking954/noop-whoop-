# Ryanbr v12 quality candidate, build 438

This branch continues `4713cca16ed91b58ba8fa7c2c9f9c333134d59b0` without merging to main.
The owner now requests upstream identity, superseding the earlier staging-only packaging decision.
The physical update remains a release-validation blocker, not a promise made by the bundle ID.

## Original archive verified

Downloaded from https://github.com/ryanbr/noop/releases/download/v12.0.0/NOOP-ios-unsigned-v12.0.0.ipa
on 23 November 2026. ZIP CRC passed, size 21,936,724 bytes, SHA-256:
`e9c2c141ea7e2e40a4f6f38ae1c9e207f729c71a9488c8a21d751ce1618d0a5b`.

| Identity | Original build 435 | Candidate build 438 |
| --- | --- | --- |
| App | com.noopapp.noop | com.noopapp.noop |
| Widget | com.noopapp.noop.widgets | com.noopapp.noop.widgets |
| App Group | group.com.noopapp.noop.staging | group.com.noopapp.noop.staging |

The `.staging` in the original App Group is intentional: removing it would change the group.
The previous selective build 436 has `com.noopapp.rebuild` as its prefix; it is not this update.
The supplied original release is verified; whether it is byte-identical to the user's pre-signing
IPA cannot be established without that file. No installed signed bundle has been obtained.

## Scope and checks

- Build configuration restores the original prefix for app and widgets; no source re-identification
  of the database, defaults, BLE restoration ID or widget group.
- Build number advances to 437. Existing health/workout reliability fixes remain from build 436.
- No speculative BLE changes, new sensor formula, schema change or new physiological feature.
- The app now presents as `NOOP` rather than the internal `NOOP Staging` product name, without
  changing the app, widget, App Group, database, defaults or BLE restoration identities.
- The first-run consent screen and shared surfaces use a calmer, denser visual hierarchy. These are
  presentation-only changes and do not alter scoring, sync cadence or background behaviour.
- New archive gate compares the built IPA against the hash-pinned original release, checks identities,
  group entitlements, arm64 executables, version consistency, ZIP CRC and absence of a personal profile.
- Existing v1-v47 migrations are checked byte-for-byte against the upstream source. The only new
  migration definitions remain additive v48/v49 from build 436.
- A new migration regression opens a populated v47 WAL database concurrently as both launch clients,
  comparing every existing user table before/after, with synthetic pairing, workout, journal, SpO2,
  heart-rate and cursor records. This is synthetic data, not the user's database.
- Existing widget group remapping tests now run in the iPhone test host as well as the macOS suite.
- Simulator reinstall checks retention of a synthetic Documents sentinel under the same identifier.
  This is a same-candidate reinstall, not an original-v12-to-candidate SideStore test.
- Package tests, iPhone hosted regression tests, simulator build/launch and Release device compilation
  remain gates. The historical Intel macOS Metal abort must be disclosed if encountered; a green job
  with that warning does not establish that macOS hosted tests ran.

## SideStore identity and remaining blocker

Inspected SideStore source at `4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6`:
`SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift` and
`ResignAppOperation.swift` in https://github.com/SideStore/SideStore .
It can reuse the installed resigned identifier for the matching team, append the team ID, or use a
custom target identifier. It also rewrites extension IDs and provisioned groups. The user's version,
custom options, team, installed signed application-identifier/keychain groups, extension IDs and
actual entitlements have not been inspected. Matching unsigned IDs is necessary but insufficient.
NOOP already resolves `ALTAppGroups` at runtime; changing signing options or team can still select a
different container. HealthKit grants and CoreBluetooth bonding cannot be exercised in CI.

Before any physical update is called safe, preserve and independently verify an original-app backup
(including committed WAL and settings), confirm the existing SideStore entry's signed identity/team,
and validate an update through that existing entry with the same signing choices. Do not uninstall,
deactivate or reset the original app to get around an install error. Do not switch the identity to
make installation succeed. A schema-49 candidate must not be treated as permitting a safe downgrade
to original v12; an original pre-update backup is required for a recovery plan.

Manifest flags `physical_device_validated`, `installed_signed_identity_verified` and
`safe_for_in_place_data_migration` stay false. Hardware pairing, actual SpO2, overnight reconnection,
workout sync, HealthKit grants/background execution and battery behaviour remain unverified.

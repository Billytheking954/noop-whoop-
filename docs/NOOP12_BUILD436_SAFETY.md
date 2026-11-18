# Ryanbr 12 selective rebuild: build 436 safety changes

Base reviewed: `c0b23fdf0a54026cb8d5fdae5115215be9d4312a`.
Foundation remains Ryanbr 12 at `7acce06c3d22cb5dfe959f2c4a43902471d21332`.
This is a staging sideload candidate, not an authorization to replace a production database.

## Changes and regression evidence

- SQLite checkpoint reads its result row and rejects `busy != 0`. Backups and rollback copies use
  SQLite online snapshots, including committed WAL pages. `CheckpointBusyTests` pins a real reader;
  `BackupSyncRoundTripTests` covers WAL-only data, failed removal/copy, rollback failure and damaged WAL.
- Restore suspends permitted store, device-registry and finished-route writes before replacement.
  Once a pathname has been replaced, writes stay suspended until relaunch even after rollback.
  Future migration identifiers and populated databases without GRDB metadata are refused in place.
  `Schema49CompatibilityTests` covers forward-only admission and v47-to-v49 compatibility.
- Backups include a bounded, versioned `workout-routes.json` payload with the original recorded points.
  The payload is validated before database replacement; all preference data is encoded before mutation.
  Old routes are kept beside the rollback database. Legacy backups clear unrelated route associations.
  `WorkoutRouteBackupTests` and the actual ZIP/restore round trip check exact point preservation.
- Workout completion writes an atomic local queue before clearing the active-session recovery snapshot.
  Failed database/route persistence leaves the exact original row and route available for retry on
  relaunch. Enqueue failure leaves the session paused and visible. Corrupt queues are preserved.
  Backup and restore refuse a known pending completion rather than silently omitting it.
- HealthKit replacement saves before retiring the exact previously observed records. Failed reads
  cannot overwrite known values with nil, route lookup is scoped to its owning workout, read-only
  prior authorization resumes imports, and route errors finish the continuation. Workouts and
  low-volume nutrition samples have additive UUID-identity tables (v48/v49).
- Repository refresh uses throwing reads and publishes only a complete successful refresh. A failed
  refresh retains the last good snapshot and exposes a retry error. The duplicate iPhone initial
  refresh was removed. `RepositoryRefreshFailureTests` renames a real input table to exercise failure.
- The sideload entitlement template now retains and verifies HealthKit background delivery.
- The workflow runs package tests, shared Swift tools, macOS tests, real iPhone simulator unit tests,
  Python repository acceptance and localization checks before packaging the IPA. Intel macOS runners
  avoid the observed arm64 runner-acquisition cancellations. Shared iOS/macOS regression sources are
  compiled into each platform's real application test host.

## Limits that must stay explicit

These changes have to pass CI at the exact source SHA; this document is not a test result.
The simulator cannot validate WHOOP radio behavior, GPS/background delivery, HealthKit permissions on
a physical phone, sideloader provisioning or long-running power behavior. Aggregate HealthKit deletions
and legacy records without UUID provenance still require real-device reconciliation evidence; a bounded
reread alone is not proof that every deleted aggregate was removed. The bridge preserves last-good
values when Apple does not distinguish an empty read from denied access. No broad destructive purge is
introduced to hide that uncertainty.

The route payload is Apple-specific because Apple's existing route store is in preferences; it does
not change the shared settings whitelist or invent an Android route schema. Database and preference
replacement are not a single filesystem transaction. Interrupted restore across those stores requires
fault-injection and real-device validation before in-place migration can be called safe. Keep the
recovery database and its route JSON together. Finished route retention remains the existing 400 cap.

The IPA uses the staging app/widget identities and shared staging App Group, contains no Watch payload,
and requires user-side re-signing. The manifest must retain `physical_device_validated: false` and
`safe_for_in_place_data_migration: false` until separate evidence justifies changing them. Research
SpO2 remains unverified and excluded from production health scoring. Ryanbr's native interface remains
the design foundation.

## 18 November build follow-up

The run for `8ea44fb30a2c323d73922660cfe64f283ee7ca59` failed and produced no artifacts.
The macOS test target lacked two required awaits in the repository read-failure regression;
three package tests still expected schema 18 after the explicit schema-49 compatibility changes;
and the Android copy of the shared oracle had not received the Apple-only identity table entries.
The repair synchronises the fixture without adding Apple HealthKit tables to Android, retains
the exact schema assertions at 49, and awaits the fault-injection writes before refreshing.

The parity inventory also predates the selective additions. The stale-base repair re-derives
the inventory against the exact previous commit and must introduce no new semantic differences
or exceptions. Energy Reserve remains Apple-only as documented in the rebuild decision record;
existing cross-platform differences remain visible in the regenerated baseline.
No test or packaging prerequisite is removed. Apple compilation and hosted test results must be
checked on the new commit before claiming a new IPA is validated.

Local follow-up validation: the exact-base derived-metadata repair passed with 298 existing
findings retained; all 50 parity acceptance tests passed against the refreshed inventory.
The full Python tools run had only the two stale-inventory failures before that refresh
(336 other tests passed). The capture suite ran 234 tests with one skipped and no failures.
Source hygiene, localisation and diff whitespace checks passed. Swift/Xcode are unavailable
in the local Linux environment; the new GitHub build remains the Apple verification gate.

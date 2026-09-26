# NOOP V2 on iPhone

NOOP V2 is an iPhone-only WHOOP companion based on NOOP 11.8. This document describes the supported application target in this fork.

## Supported product

The end-user product is:

- `NOOPiOS`, the iPhone application
- `NOOPiOSWidgets`, the required WidgetKit / Live Activity extension

The V2 repository does not ship an Android app, macOS app, standalone watchOS app, or universal iPhone+iPad product.

Both iOS targets are configured for iPhone device family only.

## Main capabilities

The iPhone application retains the fork's approved production and V2 functionality, including:

- WHOOP BLE scanning, pairing and connection
- reconnect and history synchronization
- local data storage
- Recovery, Strain, Sleep, Stress and workouts
- HealthKit permissions and production integration
- canonical HealthKit/evidence research architecture where intentionally included
- Night Lab capture, replay, inspection and import/export
- diagnostics and developer interfaces intentionally retained for V2
- experimental SpO₂ research tooling, clearly separated from production decisions

## Experimental SpO₂ boundary

SpO₂ remains experimental instrumentation. The historical candidate byte `@82` is not physiologically verified.

It is not a production input to Recovery, Strain, sleep scoring, HealthKit writes, health recommendations or clinical claims.

## Generate and open the iPhone project

```bash
brew install xcodegen
git clone https://github.com/Billytheking954/noop-whoop-.git
cd noop-whoop-
xcodegen generate
open Strand.xcodeproj
```

Select the `NOOPiOS` scheme.

## Simulator development

Use an iPhone Simulator for UI, navigation and regression work. Simulator success establishes neither physical BLE behavior nor installable release signing.

```bash
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Physical iPhone development

To install a development build on a physical iPhone, use a valid Apple development team and profiles capable of signing the app and widget with the required App Group and HealthKit capability.

The repository's signing values are deliberately configurable. Private certificates, profile bytes and passwords must remain outside source control.

WHOOP BLE operation, HealthKit authorization, background behavior and widget runtime behavior must ultimately be tested on a physical iPhone. A simulator cannot establish those results.

## Formal V2 IPA

The final signed artifact is produced by `.github/workflows/iphone-final-release.yml` from the exact final `main` commit.

The release workflow:

1. verifies that the selected SHA is the current `main` HEAD,
2. verifies ancestry from the recorded NOOP 11.8 baseline,
3. regenerates the Xcode project from `project.yml`,
4. runs release-critical validation,
5. creates a fresh generic physical-iPhone Release archive,
6. validates the app and widget provisioning profiles,
7. signs the widget and app,
8. performs strict code-sign verification,
9. packages a fresh `Payload/NOOP.app`,
10. verifies iPhone-only identity and provenance,
11. generates checksums and a release manifest,
12. publishes an immutable GitHub Release targeting the same SHA.

The expected artifact naming form is:

```text
NOOP-V2-11.8-base-<real-short-sha>-iphone.ipa
```

## iPhone-only invariants

The final V2 product must satisfy all of these:

- `TARGETED_DEVICE_FAMILY = 1`
- generic physical-iOS Release archive
- arm64 application executable
- no embedded Watch app
- no standalone watchOS artifact
- no iPad device family declaration
- exactly the intended widget extension
- matching app and widget bundle identities
- matching App Group capability
- HealthKit entitlement on the application profile
- valid signatures and embedded provisioning profiles
- embedded source/provenance metadata matching the GitHub Release target

`Tools/verify_iphone_ipa.py` enforces the archive-level identity/provenance checks, while the workflow separately performs cryptographic `codesign` verification.

## Physical-device release checklist

A successfully signed and verified IPA is release-built, but physical runtime validation remains a separate evidence step. It includes installation, launch/relaunch, navigation, WHOOP scan/pair/reconnect, live heart rate, history sync, background/foreground transitions, offline launch, HealthKit permissions/import behavior, scoring screens, Night Lab, experimental SpO₂ labeling, widgets, persistence and sync performance.

Do not mark any of those as passed without actually running them on a physical iPhone.

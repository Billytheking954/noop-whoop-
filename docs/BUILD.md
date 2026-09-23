# Building NOOP V2 for iPhone

NOOP V2 is an offline iPhone WHOOP companion based on NOOP 11.8. The supported end-user product in this fork is the iPhone app plus its required iPhone widget extension.

It is not a macOS, Android, iPad-universal or standalone watchOS product.

> NOOP V2 is not affiliated with WHOOP, Inc. and is not a medical device. See `DISCLAIMER.md` and `ATTRIBUTION.md`.

## Requirements

- macOS with a current Xcode installation capable of building the configured iOS 17 deployment target
- XcodeGen
- Git
- for physical-device installation: a valid Apple signing certificate, matching iPhone provisioning profiles for the app and widget, and the required HealthKit/App Group capabilities

Install XcodeGen with Homebrew:

```bash
brew install xcodegen
```

## Repository layout

```text
Strand/                  Shared Swift application/core code used by iPhone
StrandiOS/               iPhone application shell and iOS integrations
StrandiOSShared/         Code shared by the iPhone app and widget
StrandiOSWidgets/        Required WidgetKit / Live Activity extension
StrandTests/             iPhone-hosted app regression tests
Packages/                Swift packages used by the iPhone product
Tools/                   Validation, research, capture and release tooling
project.yml              XcodeGen source of truth
```

`Strand.xcodeproj` is generated and is intentionally not committed as a release source artifact.

## Generate the project

```bash
git clone https://github.com/Billytheking954/noop-whoop-.git
cd noop-whoop-
xcodegen generate
open Strand.xcodeproj
```

Use the `NOOPiOS` scheme.

The application and widget are explicitly configured with:

```text
TARGETED_DEVICE_FAMILY = 1
```

so the V2 product is iPhone-only rather than a universal iPhone+iPad application.

## Simulator build

A simulator build is useful for compile and UI regression work, but it is not an installable release IPA.

```bash
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## App tests

The app regression suite is hosted by the iPhone target rather than a retired macOS application target.

A typical local run is:

```bash
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Use any available iPhone simulator supported by the installed Xcode runtime.

## Swift package tests

The iPhone app depends on reusable Swift packages including WHOOP protocol/storage, analytics, import, design, health and HealthKit layers. Package tests can be run independently where their platform dependencies permit:

```bash
swift test --package-path Packages/WhoopProtocol
swift test --package-path Packages/WhoopStore
swift test --package-path Packages/StrandAnalytics
swift test --package-path Packages/StrandImport
swift test --package-path Packages/StrandDesign
swift test --package-path Packages/StrandHealth
swift test --package-path Packages/StrandHealthKit
swift test --package-path Packages/OuraProtocol
swift test --package-path Packages/PolarProtocol
```

A package declaring macOS compatibility does not make macOS a supported NOOP V2 product. macOS may remain a useful Swift test host for portable package code.

## Physical iPhone development build

For a development-signed device build, provide your own bundle prefix/team configuration and let Xcode resolve matching development signing.

The app needs the capabilities represented in the repository configuration, including HealthKit and the shared App Group used by the widget.

Do not commit signing certificates, provisioning profiles, passwords or private signing values.

## Formal V2 Release archive

The formal release is produced only by `.github/workflows/iphone-final-release.yml` from the exact current `main` SHA.

The workflow creates a completely fresh generic physical-iPhone Release archive and then signs the required app and widget using approved provisioning profiles. It rejects unexpected Watch payloads or other extensions.

A simulator `.app`, unsigned archive, old upstream IPA, cached artifact or manually renamed ZIP is not a V2 release.

The formal artifact name is:

```text
NOOP-V2-11.8-base-<real-short-sha>-iphone.ipa
```

The release also generates:

- IPA SHA-256
- release manifest JSON
- release-manifest SHA-256
- IPA verification report
- release notes

See `docs/IPHONE_RELEASE_POLICY.md` for the source-to-IPA contract.

## Signing secrets used by CI

The final workflow expects repository secrets equivalent to:

```text
IOS_SIGNING_CERTIFICATE_P12_BASE64
IOS_SIGNING_CERTIFICATE_PASSWORD
IOS_APP_PROVISIONING_PROFILE_BASE64
IOS_WIDGET_PROVISIONING_PROFILE_BASE64
IOS_SIGNING_TEAM_ID
IOS_BUNDLE_ID_PREFIX
IOS_KEYCHAIN_PASSWORD
```

Secret values are never part of release provenance or logs.

The profiles must match the configured app, widget and App Group identities. The application profile must also carry the HealthKit capability required by the iPhone application.

## Release verification

Before publication, the release workflow verifies at least:

- exact source SHA equals current `main`
- ancestry from the recorded NOOP 11.8 baseline
- iPhone-only project invariants
- fresh XcodeGen generation
- release-critical Swift/Python/localisation validation
- physical-iPhone `arm64` archive
- exactly one application and the expected widget extension
- no Watch payload
- app and widget provisioning profiles
- Team ID / identifiers / App Group compatibility
- HealthKit entitlement on the app profile
- strict app and widget code signatures
- `UIDeviceFamily == [1]`
- embedded source provenance
- expected version/build/bundle identity
- SHA-256 and manifest generation
- GitHub Release target equals the same source SHA

If any identity or provenance check disagrees, the release fails closed.

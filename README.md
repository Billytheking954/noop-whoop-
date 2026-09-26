<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP" width="72">
</p>

<h1 align="center">NOOP V2 for iPhone</h1>

<p align="center"><b>Offline iPhone WHOOP companion based on NOOP 11.8 · Night Lab · HealthKit · local data · evidence-first research</b></p>

> [!IMPORTANT]
> **NOOP V2 is an iPhone-only personal development fork of NOOP 11.8.** It is not the canonical upstream repository and is not affiliated with WHOOP, Inc. The supported end-user product in this repository is the iPhone app. Android, macOS, iPad-universal and standalone watchOS products are not release targets.

## Product scope

NOOP V2 keeps the mature NOOP iPhone functionality and adds the fork's approved V2 work while making evidence, provenance and release identity explicit.

The supported product includes:

- iPhone UI and required iPhone widget extension
- direct WHOOP BLE scanning, pairing, reconnect, live data and history sync
- local persistence and established production analytics
- Recovery, Strain, Sleep, Stress and workouts
- HealthKit integration and the canonical health-evidence architecture
- Night Lab capture, sealed archives, deterministic replay, inspection, import/export and evidence-quality summaries
- developer/diagnostic surfaces intentionally retained on iPhone
- experimental SpO₂ instrumentation kept separate from production decisions
- provenance-locked iPhone release tooling

The repository intentionally does **not** ship an Android app, macOS app, standalone watchOS app or universal iPhone+iPad product.

## Current V2 status

| Area | Status |
|---|---|
| Upstream baseline | NOOP 11.8 |
| App version | 11.8.0 |
| Build number | 400 |
| Supported device family | iPhone only |
| iPhone widget | Retained |
| Night Lab foundation/replay/archive validation | Integrated |
| Night Lab evidence-quality summaries | Integrated |
| Canonical health evidence/store/coordinator | Integrated |
| Canonical HealthKit provider/debug validation lane | Integrated |
| Experimental SpO₂ tooling | Integrated as research/instrumentation only |
| Candidate SpO₂ byte `@82` | **Unverified** |
| Production SpO₂ use | **None** |
| Final signed IPA | Valid only when the final-release workflow succeeds for the exact `main` SHA |

## Night Lab

Night Lab is the V2 evidence and replay environment for investigating overnight data without quietly changing the production sleep algorithm to make an experiment look better.

V2 includes, as applicable to the merged code:

- schema-versioned sealed archives
- strict evidence windows
- raw evidence preservation
- SHA-256 asset validation
- decoded sample/row counts
- device, firmware, application and algorithm provenance
- deterministic replay through the production staging adapter
- saved baseline/hypnogram evidence
- execution receipts
- signal coverage and missing-data inspection
- evidence-quality summaries
- archive-integrity versus physiological-accuracy separation
- deterministic `.nightlab` import/export
- corruption, overwrite, rollback and path-traversal protections
- developer inspection UI

See [`docs/NIGHT_LAB.md`](docs/NIGHT_LAB.md).

## HealthKit and canonical health evidence

`Packages/StrandHealth` and `Packages/StrandHealthKit` provide the V2 canonical evidence architecture and HealthKit provider work.

Important invariants include:

- explicit source/provenance and metric semantics
- atomic observation/deletion/cursor commits
- incremental anchored HealthKit reads
- first-class deletions
- provider cursor handling
- app-authored sample exclusion where configured
- SDNN kept distinct from RMSSD
- oxygen-saturation source units handled semantically rather than by guesswork
- debug validation lanes kept separate from production behavior unless deliberately promoted

The canonical work does not silently replace established production HealthKit behavior merely because a cleaner abstraction exists.

## Experimental SpO₂

> [!CAUTION]
> SpO₂ in this fork is **experimental research/instrumentation only**.

The historical v18 candidate byte `@82` is not treated as physiologically verified. Synthetic or structural validation is not independent physiological validation.

Experimental SpO₂ is excluded from:

- Recovery
- Strain
- production sleep scoring/staging decisions
- production HealthKit writes
- health recommendations or warnings
- clinical claims

A plausible number is not evidence. Wearable telemetry has already supplied humanity with enough confident decimals.

## Production-safety boundary

Unless an explicitly reviewed release change states otherwise, V2 preserves the established production behavior for:

- Recovery and Strain coefficients
- Sleep score and production `SleepStagerV2`
- Stress scoring
- HRV and resting heart rate semantics
- respiration
- workouts
- WHOOP BLE protocol operation/history sync
- database semantics
- production HealthKit behavior
- production SpO₂, which remains absent

Open experimental or production-changing PRs are not release content merely because they exist.

## iPhone-only repository layout

```text
NOOP V2
├── Strand/                  Shared Swift application/core code required by iPhone
├── StrandiOS/               iPhone application shell and iOS integrations
├── StrandiOSShared/         Components shared by the iPhone app and its widget
├── StrandiOSWidgets/        Required iPhone widget / Live Activity extension
├── Packages/                Swift packages required by the iPhone product
├── StrandTests/             iPhone-hosted regression tests
├── Tools/                   Validation, capture/research and release tooling
├── docs/                    iPhone/product/protocol documentation
└── .github/workflows/       iPhone CI, package/tool tests and final IPA release
```

Some tools are host-agnostic and run on Linux or Windows because that is a cheap way to regression-test WHOOP frame/capture logic. Those runner operating systems are **test environments**, not supported NOOP products.

## Build from source

Requirements:

- macOS with Xcode capable of the configured iOS deployment target
- XcodeGen
- your own valid Apple development signing setup for physical devices

```bash
git clone https://github.com/Billytheking954/noop-whoop-.git
cd noop-whoop-
brew install xcodegen
xcodegen generate
open Strand.xcodeproj
```

Use the `NOOPiOS` scheme. The generated project declares `TARGETED_DEVICE_FAMILY = 1` for both the app and widget.

`Config/BundleId.xcconfig` supports the repository's bundle settings. Do not commit private certificates, provisioning profiles or secret values.

## Final signed IPA policy

The only user-facing application artifact for a formal V2 release is:

```text
NOOP-V2-11.8-base-<real-short-sha>-iphone.ipa
```

The authoritative workflow is [`.github/workflows/iphone-final-release.yml`](.github/workflows/iphone-final-release.yml).

A formal release is fail-closed. It must:

1. use the exact current `main` SHA,
2. prove ancestry from the recorded NOOP 11.8 baseline,
3. regenerate the Xcode project,
4. rerun release-critical validation,
5. create a fresh generic physical-iPhone Release archive,
6. use the app and widget provisioning profiles plus signing certificate,
7. sign the widget then the app,
8. pass strict cryptographic signature verification,
9. contain exactly one iPhone app and the expected widget,
10. contain no Watch payload,
11. report `UIDeviceFamily = [1]`,
12. contain an arm64 executable,
13. embed source/provenance metadata,
14. pass `Tools/verify_iphone_ipa.py`,
15. generate an IPA SHA-256, release manifest and release notes,
16. publish an immutable GitHub Release whose target is the same SHA.

An unsigned `.app`, simulator build, stale archive, upstream IPA or old cached artifact is not the V2 release.

See [`docs/IPHONE_RELEASE_POLICY.md`](docs/IPHONE_RELEASE_POLICY.md).

## CI and validation

Current supported validation lanes include:

- iPhone Simulator build and iPhone-hosted app tests
- Swift package tests used by the iPhone application
- iPhone localisation coverage
- source/repository hygiene, including iPhone-only invariants
- Linux WHOOP capture/decoder regression tests
- Windows decoder regression tests where encoding/platform behavior is useful to the tooling
- final signed IPA identity, provenance and structure verification

CI runners do not redefine the supported product platform.

## Release scope

The release scope lock is stored in [`.github/release/iphone-v2-final.json`](.github/release/iphone-v2-final.json). Open work that changes production stress behavior or advances experimental Night Lab Phase 2 remains outside the V2 freeze unless separately reviewed and merged.

## Privacy and safety

NOOP V2 is local-first. Night Lab and canonical evidence work are intended to improve traceability, not create a cloud dependency.

NOOP V2 is **not a medical device**. Heart rate, HRV, recovery, strain, sleep stages, respiratory metrics, temperature-derived values and experimental SpO₂ outputs must not be treated as clinical measurements or used to diagnose or treat a medical condition.

See [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md) and [`DISCLAIMER.md`](DISCLAIMER.md).

## Upstream and attribution

This fork is based on the NOOP project and its contributors. Canonical upstream repository:

**https://github.com/ryanbr/noop**

Important credits include:

- `ryanbr/noop`, the canonical NOOP project and base for this fork
- `johnmiddleton12/my-whoop`, WHOOP interoperability work
- `b-nnett/goose`, WHOOP protocol documentation used by NOOP
- `groue/GRDB.swift`, SQLite persistence
- `weichsel/ZIPFoundation`, archive support

See [`ATTRIBUTION.md`](ATTRIBUTION.md) and [`NOTICE`](NOTICE). Existing license, copyright, attribution and third-party obligations remain in force.

## License

NOOP is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE).

This repository is a personal/non-commercial development fork. It does not claim affiliation with WHOOP, Inc., Apple, Oura, or the upstream NOOP maintainers.

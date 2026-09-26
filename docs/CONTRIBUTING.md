# Contributing to NOOP V2

NOOP V2 is an offline, iPhone-only WHOOP companion based on NOOP 11.8. The supported end-user product is the iPhone application plus its required widget extension.

> This project is not affiliated with WHOOP, Inc. and is not a medical device. Preserve `LICENSE`, `NOTICE`, `ATTRIBUTION.md` and the repository's safety boundaries.

## Ground rules

1. **iPhone is the product.** Do not add Android, macOS, standalone watchOS or universal iPad product targets back to this fork without an explicit future product decision.
2. **Keep data local-first.** New network behavior must be explicit, justified and documented.
3. **Do not make destructive BLE changes casually.** The strap is real hardware. Keep write commands curated, reversible where possible, and covered by protocol tests.
4. **Evidence before confidence.** Wearable values need provenance, semantics and validation. Plausible numbers are not proof.
5. **Keep production and research separate.** Experimental Night Lab or SpO₂ work must not silently alter Recovery, Strain, Sleep, Stress, HealthKit production writes or health recommendations.
6. **Preserve attribution.** Credit upstream NOOP and protocol-research contributors.
7. **Do not commit secrets.** Certificates, provisioning profiles, signing passwords and private identifiers belong in secure CI configuration, not source control.

## Repository map

```text
Strand/                  Shared Swift application/core code required by iPhone
StrandiOS/               iPhone app shell and iOS integrations
StrandiOSShared/         App/widget shared iOS code
StrandiOSWidgets/        Required WidgetKit / Live Activity extension
StrandTests/             iPhone-hosted application tests
Packages/                Protocol, storage, analytics, import, design and health packages
Tools/                   Validation, research, capture and release tooling
docs/                    Product, protocol and research documentation
project.yml              XcodeGen source of truth
```

`Strand.xcodeproj` is generated. Do not hand-edit or commit it.

## Where changes belong

| Change | Preferred location |
|---|---|
| WHOOP bytes, framing, CRC, event/packet decode | `Packages/WhoopProtocol` |
| Persistence, migrations, caches | `Packages/WhoopStore` |
| Recovery/Strain/Sleep/HRV math | `Packages/StrandAnalytics` |
| Importers | `Packages/StrandImport` |
| Reusable iPhone design components/charts | `Packages/StrandDesign` |
| Canonical health evidence | `Packages/StrandHealth` |
| Canonical HealthKit provider | `Packages/StrandHealthKit` |
| CoreBluetooth / collection / iPhone app behavior | `Strand/` and `StrandiOS/` |
| Widget / Live Activity | `StrandiOSWidgets/` and `StrandiOSShared/` |
| Night Lab | existing Night Lab sources/packages/docs, preserving deterministic evidence boundaries |
| Research/capture utilities | `Tools/` |

Some Swift packages may continue to declare macOS compatibility because macOS is a useful test host for portable Swift code. That compatibility is not a macOS NOOP product target.

## Build and test

Generate the project:

```bash
brew install xcodegen
xcodegen generate
open Strand.xcodeproj
```

Use the `NOOPiOS` scheme.

For package changes, run the relevant package tests. For app changes, run the iPhone Simulator build and iPhone-hosted test suite. See `docs/BUILD.md` for exact commands.

Pull-request CI covers:

- iPhone build and app tests
- required Swift package tests
- iPhone localisation
- source and iPhone-only repository hygiene
- WHOOP capture/decoder regression tests on Linux
- Windows decoder regression tests where host behavior matters

Linux and Windows are test environments for host-agnostic tooling, not supported application platforms.

## iPhone-only invariants

Do not reintroduce:

- `android/`
- Android Gradle/manifests/resources/product workflows
- macOS application targets or distribution scripts
- standalone watchOS targets
- embedded Watch payloads
- `TARGETED_DEVICE_FAMILY = "1,2"`
- cross-platform Swift/Kotlin parity governance that exists only to keep a retired Android app aligned
- old multi-platform release workflows

`Tools/verify_iphone_only_repo.py` guards these invariants.

## BLE safety

Before changing scanning, pairing, reconnect, history sync, frame reassembly, CRC handling, acknowledgements or write commands:

- understand the existing protocol path,
- preserve device-family handling,
- add or update deterministic protocol tests,
- avoid undocumented destructive commands,
- do not use a physical strap as a substitute for unit tests.

The Linux capture/decoder workbench may remain because it helps verify evidence and protocol behavior used by the iPhone product.

## HealthKit safety

Keep semantic distinctions explicit. In particular:

- SDNN is not RMSSD,
- oxygen saturation units must be interpreted correctly,
- deletions remain deletions,
- cursors must not move independently of committed observations,
- app-authored samples must not create read/write loops,
- debug validation lanes stay debug-only unless intentionally promoted.

## Night Lab

Night Lab is an evidence/replay system, not an excuse to change production staging until an experiment is validated.

Preserve:

- sealed evidence archives,
- provenance and sample counts,
- SHA-256 integrity,
- deterministic replay,
- corruption handling,
- strict evidence windows,
- archive integrity versus physiological accuracy separation.

## Experimental SpO₂

SpO₂ remains experimental instrumentation. Candidate byte `@82` is unverified unless genuine independent evidence demonstrates its identity.

Do not wire experimental SpO₂ into production Recovery, Strain, Sleep scoring, HealthKit writes, warnings or clinical claims.

## Pull requests

Keep PRs narrow enough to review and classify. A branch being open does not make it release content.

For release-bound work:

- state the production behavior changed, or explicitly state that none changed,
- report the exact tests run,
- distinguish synthetic/structural validation from real physiological or physical-device validation,
- avoid claiming pending CI as passing.

## Releases

Only `.github/workflows/iphone-final-release.yml` is authoritative for the formal V2 IPA.

Do not publish an old IPA, upstream-only IPA, Simulator `.app`, unsigned placeholder, cached archive or manually repackaged file as the release.

The final IPA must prove its exact `main` SHA, signing identity/profile compatibility, iPhone-only device family, arm64 architecture and provenance. See `docs/IPHONE_RELEASE_POLICY.md`.

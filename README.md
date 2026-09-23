<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP" width="72">
</p>

<h1 align="center">NOOP V2 — Personal WHOOP Companion Fork</h1>

<p align="center"><b>NOOP 11.8 base · iPhone-first · local data · Night Lab · HealthKit provenance · experimental WHOOP research</b></p>

<p align="center">
  <img alt="Base" src="https://img.shields.io/badge/base-NOOP%2011.8-E8B84B?style=flat-square">
  <img alt="Primary platform" src="https://img.shields.io/badge/primary-iPhone%20%2F%20iOS-E8B84B?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/data-local--first-C8902F?style=flat-square">
  <img alt="WHOOP" src="https://img.shields.io/badge/focus-WHOOP%205.0%20%2F%204.0-6B737B?style=flat-square">
  <img alt="Experimental" src="https://img.shields.io/badge/research-experimental-6B737B?style=flat-square">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-6B737B?style=flat-square"></a>
</p>

> [!IMPORTANT]
> This is a **personal development fork of NOOP**, based on the NOOP 11.8 code line. It is not the
> canonical upstream repository and it is not affiliated with WHOOP, Inc.
>
> The fork is being developed primarily as an **iPhone/WHOOP companion and research build** with a
> strong emphasis on local data ownership, sleep evidence, Apple Health interoperability, provenance,
> validation, and release traceability.

---

## What this fork is for

This fork exists to turn the already-capable NOOP project into a more inspectable and trustworthy
personal wearable companion.

The main priorities are:

- **Use the WHOOP strap directly** without depending on the WHOOP cloud for the fork's local workflows.
- Make **iPhone/iOS the primary release target** for this fork.
- Keep health and wearable data **local-first** and source-aware.
- Make sleep analysis easier to investigate rather than treating an algorithm result as magic.
- Preserve the distinction between **raw evidence, derived metrics and experimental hypotheses**.
- Improve Apple Health ingestion without silently replacing the existing production path before it is validated.
- Explore WHOOP 5 data such as SpO₂ without pretending an experimental decoder is medically or physiologically proven.
- Make every formal IPA traceable to the **exact Git commit that created it**.

This is deliberately not a "change everything at once" fork. Production scoring and mature behaviour
stay stable while new architecture and research paths are built beside them and validated.

---

## Fork status

| Area | Current status |
|---|---|
| **Upstream base** | ✅ NOOP 11.8 (`11.8.0` application version line) |
| **Primary fork platform** | ✅ iPhone / iOS |
| **WHOOP 4.0** | ✅ Existing NOOP support retained |
| **WHOOP 5.0 / MG** | 🧪 Active focus; existing support retained while deeper evidence remains experimental |
| **Night Lab foundation** | ✅ Merged |
| **Deterministic Night Lab replay** | ✅ Merged |
| **Night Lab archive integrity / provenance** | ✅ Merged |
| **Canonical health evidence model** | ✅ Merged |
| **Atomic canonical observation store** | ✅ Merged |
| **Incremental observation coordinator** | ✅ Merged |
| **HealthKit canonical quantity provider** | ✅ Merged |
| **Real-app canonical HealthKit debug lane** | ✅ Merged, DEBUG-only |
| **All canonical HealthKit quantity debug exercise** | ✅ Merged, DEBUG-only |
| **Experimental SpO₂ research tooling** | 🧪 Present, research/instrumentation only |
| **Production scoring changes** | ⛔ Deliberately not part of the current V2 fork work |
| **Production SleepStagerV2 changes** | ⛔ Deliberately not part of the current V2 fork work |
| **Formal V2 iPhone IPA** | 🚧 Not published until the provenance-locked release workflow completes successfully |

---

# What has been added in this fork

## 1. Night Lab

Night Lab is the fork's evidence and replay environment for investigating sleep and overnight data
without changing the production sleep algorithm simply to make a test look better.

The merged foundation includes:

- schema-versioned sealed Night Lab archives
- strict time boundaries for captured evidence
- per-asset SHA-256 integrity checks
- decoded row-count verification
- write-once raw and derived evidence
- source, device, firmware and algorithm provenance
- deterministic replay through the existing production `SleepStagerV2` adapter
- stored hypnogram / replay inspection
- signal coverage and gap inspection
- deterministic `.nightlab` bundle export/import
- corruption, overwrite, rollback and path-traversal protections
- idempotent import of identical evidence
- developer-facing inspection UI

### Why it exists

Sleep research is easy to fool accidentally. A graph can look convincing while its source data is
missing, sparse, shifted or from the wrong device. Night Lab is designed to keep the evidence attached
to the result so future changes can be tested against the same night reproducibly.

See [`docs/NIGHT_LAB.md`](docs/NIGHT_LAB.md).

---

## 2. Canonical health evidence and provenance

The fork adds a provider-independent health evidence layer in `Packages/StrandHealth`.

It introduces explicit structures for:

- observations
- measurement source/provenance
- metric semantics
- units and quality state
- algorithm identity
- derived-metric traceability
- provider cursors
- first-class deletions
- atomic change batches

This is meant to stop one of the nastier classes of health-app bugs: two values looking identical after
the system has forgotten **where they came from, what they meant, or how they were derived**.

### Atomic observation store

The canonical store commits observations, deletions and the provider's next cursor as one transaction.
A stale cursor cannot quietly overwrite newer state.

### Incremental ingestion coordinator

The coordinator:

1. loads the currently committed provider cursor,
2. asks that provider for the next bounded set of changes,
3. verifies provider identity,
4. commits the changes and next cursor atomically.

That creates a clean seam for HealthKit now and other sources later.

---

## 3. Canonical HealthKit ingestion work

`Packages/StrandHealthKit` adds a read-only, anchored HealthKit quantity provider that feeds the new
canonical evidence architecture.

Important properties of the current implementation:

- incremental anchored reads
- deletion-aware ingestion
- bounded batches
- explicit metric semantics
- preserved source/provenance
- HealthKit oxygen saturation retains its source fraction semantics before canonical conversion
- SDNN is not silently relabelled as RMSSD
- NOOP-authored samples can be excluded from read-back
- ambiguous body-vs-skin temperature mapping is deliberately not guessed

### Real iOS debug validation lane

The iOS application now contains an explicit **DEBUG-only** path that exercises the canonical pipeline
from the real app.

Two launch arguments exist:

```text
--canonical-healthkit-sync
--canonical-healthkit-sync-all
```

The first performs a bounded heart-rate transaction. The second exercises every currently defined
canonical HealthKit quantity stream sequentially, with an independent cursor for each stream.

Failures are isolated per stream and the debug logging reports stream identity and counts rather than
printing private health values.

### What this does NOT mean

The existing production `HealthKitBridge` has **not** been replaced. Production HealthKit observers,
write-back, scoring and background behaviour stay on the established path while the canonical path is
validated.

That separation is intentional.

---

## 4. Experimental WHOOP SpO₂ research

This fork contains experimental SpO₂ decoding and evidence-quality work for investigating WHOOP data.

Current work includes areas such as:

- candidate frame decoding
- frame/shape checks
- quality filtering
- experimental aggregation
- evidence completeness checks
- Night Lab diagnostics
- explicit missing/no-overlap handling
- regression tests around malformed or insufficient evidence

> [!CAUTION]
> **Experimental SpO₂ is not a production health metric.**
>
> It is not used as a medical measurement, health warning, or validated production recovery input.
> A plausible-looking oxygen percentage is not enough evidence to promote a decoder. Real validation
> requires appropriately aligned independent reference recordings and sufficient overlap.

Some later SpO₂ validation work remains in separate/open research branches and must not be described as
released merely because the branch exists.

---

## 5. Release provenance and IPA safety

The fork now has a separate final iPhone release workflow designed around one rule:

> **The downloadable IPA must prove which exact source commit produced it.**

The legacy fork workflow that could publish Android, macOS and an unsigned iOS payload as one release is
blocked for final-release use.

The new final path is iPhone-only and fail-closed.

### A formal release must record

- repository
- branch
- full Git SHA
- short Git SHA
- upstream NOOP baseline
- included merged PRs
- application version
- build number
- Release configuration
- iOS/iPhone target
- IPA filename
- SHA-256 checksum
- build date

### The workflow refuses to continue when

- the requested SHA is not the exact selected `main` HEAD
- the commit does not descend from the recorded NOOP 11.8 baseline
- the source tree is dirty
- an ambiguous old `1.8` version is being released
- open PRs have not been explicitly reviewed for release scope
- a release tag already exists
- required tests fail
- required signing material is missing
- provisioning profiles do not match the expected app/widget identities
- the final payload is not an iPhone device build
- expected provenance does not match the IPA

### Final artifact naming

A formal V2 build uses the real Git SHA in the filename, for example:

```text
NOOP-V2-11.8-base-<real-short-sha>-iphone.ipa
```

or:

```text
NOOP-11.8-fork-<real-short-sha>-iphone.ipa
```

The workflow also produces a release manifest and SHA-256 checksum.

See [`docs/IPHONE_RELEASE_POLICY.md`](docs/IPHONE_RELEASE_POLICY.md).

---

# Download / install status

## Final V2 IPA

**There is deliberately no claim here that the final V2 IPA is ready yet.**

A release is only considered complete when the provenance-locked workflow has actually produced and
verified the signed iPhone IPA from the stated final commit.

A source-complete branch, simulator build, old IPA, unsigned placeholder or upstream-only NOOP package
is **not** treated as the final fork release.

When a verified release exists, it will appear in this fork's own Releases page:

**[`Billytheking954/noop-whoop-` Releases](https://github.com/Billytheking954/noop-whoop-/releases)**

Do not assume an upstream `ryanbr/noop` IPA contains this fork's V2 changes.

## Build from source

For development/testing on Apple platforms:

```bash
git clone https://github.com/Billytheking954/noop-whoop-.git
cd noop-whoop-

brew install xcodegen
xcodegen generate
open Strand.xcodeproj
```

For iPhone work, use the `NOOPiOS` scheme and your own valid Apple signing configuration.

The tracked `Config/BundleId.xcconfig` supports a local, gitignored
`Config/BundleIdSecrets.xcconfig` for your own bundle prefix and development team.

---

# What deliberately remains unchanged

The fork has added a lot of validation and research infrastructure without silently redefining the
mature production algorithms underneath it.

Unless a future reviewed change says otherwise, the current V2 work preserves:

- existing production recovery/scoring coefficients
- current production `SleepStagerV2` behaviour
- normal BLE collection behaviour
- established production HealthKit behaviour
- Night Lab deterministic replay boundaries
- existing user-data compatibility expectations
- the separation between experimental SpO₂ work and production scoring

This is important because architecture work and research tooling should not be mistaken for an
unannounced physiological-model change.

---

# Development philosophy

## Evidence before confidence

For wearable data, "the number looks right" is not enough.

The fork favours:

- reproducible evidence
- source provenance
- explicit uncertainty
- deterministic tests
- corruption detection
- no-overlap / insufficient-evidence states instead of invented statistics
- keeping experimental hypotheses labelled as experimental

## Keep production and research separate

Research code can ship inside the repository without being wired into production scoring.
That lets the experimental path be tested without turning unfinished work into a health claim.

## Fail closed on releases

If the final source-to-IPA chain cannot be demonstrated, the release is not complete.

No fallback to an older IPA. No random cached artifact. No pretending a simulator build is an iPhone
release because the filename ended in `.ipa` after enough shell scripting.

---

# Repository map

```text
Strand/                         Shared/macOS application code
StrandiOS/                      iPhone application code
StrandiOSShared/                Shared iOS/widget components
StrandiOSWidgets/               iOS widgets + Live Activity extension
Packages/
  WhoopProtocol/                WHOOP protocol parsing and experimental sensor research
  WhoopStore/                   Local persistence
  StrandAnalytics/              Recovery/strain/sleep analytics + Night Lab
  StrandImport/                 Import pipelines
  StrandDesign/                 Shared design system
  StrandHealth/                 Canonical evidence/provenance + ingestion contracts
  StrandHealthKit/              Canonical HealthKit provider
Tools/                          Validation, research and repository tooling
docs/
  NIGHT_LAB.md                  Night Lab architecture and behaviour
  IPHONE_RELEASE_POLICY.md      Fork release/provenance contract
.github/workflows/
  iphone-final-release.yml      Provenance-locked final iPhone release path
```

---

# Validation

The repository contains multiple independent validation lanes rather than one enormous CI job whose
success means nobody quite remembers what was tested.

Current gates include:

- Swift package build/tests
- iOS Simulator compile validation
- shared macOS app tests
- source hygiene checks
- i18n coverage checks
- Linux Python/tooling regression suites
- Windows decoder/tooling regression suites
- parity/governance checks where applicable
- dedicated final iPhone IPA verification

The final release workflow reruns the relevant validation against the **exact release SHA** rather than
trusting an unrelated earlier workflow run.

---

# Current research / roadmap boundaries

The repo intentionally still contains open and historical PRs. An open branch is not automatically
part of the release.

Examples of work that may remain separate until it earns promotion include:

- further Night Lab Phase 2 sleep-detection research
- richer Night Lab evidence-quality summaries
- additional SpO₂ independent-reference validation
- deeper WHOOP 5 protocol work
- eventual migration of production HealthKit reads to the canonical architecture after real validation

The release workflow therefore requires open PRs to be reviewed explicitly rather than assuming every
unfinished experiment belongs in V2.

---

# Original NOOP project

This fork is built on the work of the NOOP project and its contributors.

Canonical upstream repository:

**https://github.com/ryanbr/noop**

The upstream project provides the broad NOOP application, including its existing WHOOP protocol support,
UI, analytics, storage, imports, platform implementations and wider feature set. This fork adds the
personal V2 work described above rather than claiming those upstream features as newly created here.

If you are looking for the general NOOP community, upstream documentation or upstream multi-platform
releases, use the canonical repository.

---

# Privacy

The core goal remains local-first operation.

Wearable evidence, imports and derived metrics should stay on the device unless a feature is explicitly
configured to send something elsewhere.

The fork's new Night Lab and canonical evidence work is designed to improve **traceability**, not to add
a cloud dependency.

Read [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md) for the broader NOOP privacy model.

---

# Safety / health disclaimer

NOOP and this fork are **not medical devices**.

Heart rate, HRV, recovery, strain, sleep stages, SpO₂, respiratory metrics, temperature-derived values
and experimental research outputs must not be treated as clinical measurements simply because they are
shown in a polished interface.

Experimental decoders in particular can be wrong while still producing plausible numbers.

Do not use this software to diagnose or treat a medical condition. See [`DISCLAIMER.md`](DISCLAIMER.md).

---

# Attribution

NOOP stands on community interoperability and protocol-documentation work. Important upstream credits
include:

- [`ryanbr/noop`](https://github.com/ryanbr/noop) — canonical NOOP project and the base for this fork
- `johnmiddleton12/my-whoop` — WHOOP 4.0 interoperability work
- `b-nnett/goose` — WHOOP 5.0 / MG protocol documentation used by NOOP
- `groue/GRDB.swift` — SQLite persistence
- `weichsel/ZIPFoundation` — archive support

See [`ATTRIBUTION.md`](ATTRIBUTION.md) and [`NOTICE`](NOTICE) for the repository's full attribution and
third-party notices.

This fork does not claim affiliation with WHOOP, Inc., Apple, Oura, or the upstream NOOP maintainers.

---

# License

NOOP is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE).

The existing license, copyright notices, upstream attribution and third-party license requirements remain
in force in this fork.

This is a personal/non-commercial development fork, not a commercial redistribution of NOOP.

---

# Useful docs

- [`docs/NIGHT_LAB.md`](docs/NIGHT_LAB.md) — Night Lab capture, replay and evidence model
- [`docs/IPHONE_RELEASE_POLICY.md`](docs/IPHONE_RELEASE_POLICY.md) — exact-source iPhone release rules
- [`docs/BUILD.md`](docs/BUILD.md) — build information
- [`docs/IOS.md`](docs/IOS.md) — upstream iOS/sideloading documentation
- [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md) — privacy/security model
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — protocol documentation
- [`docs/RAW_DATA_CAPTURE.md`](docs/RAW_DATA_CAPTURE.md) — raw capture information
- [`ATTRIBUTION.md`](ATTRIBUTION.md) — credits and licensing details
- [`DISCLAIMER.md`](DISCLAIMER.md) — legal/medical disclaimer

---

<p align="center"><b>NOOP V2 fork: build carefully, measure honestly, and never let a convincing-looking number outrun its evidence.</b></p>

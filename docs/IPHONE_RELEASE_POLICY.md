# NOOP V2 final iPhone release policy

The formal NOOP V2 release is a signed iPhone IPA built from the exact final `main` commit. Simulator builds, unsigned placeholders, macOS/watchOS products, old upstream IPAs and cached artifacts are not final releases.

## Canonical identity

- Product: **NOOP V2**
- Upstream baseline: **NOOP 11.8**
- Baseline commit: `ef0c0d72f2ece1a66c625a30e1076935e584b448`
- App version: `11.8.0`
- Build number: `400`
- Platform: iOS
- Device family: iPhone only
- Configuration: Release

Fork identity belongs in release metadata, provenance and artifact naming rather than invalid Apple version fields.

## Final artifact

The user-facing application artifact is:

```text
NOOP-V2-11.8-base-<real-short-sha>-iphone.ipa
```

The real short SHA is derived from the exact source commit. No Android, macOS, standalone watchOS, iPad-universal or simulator application artifact belongs in the formal V2 release.

## Source-to-IPA chain

```text
exact current main SHA
→ clean checkout
→ XcodeGen generation
→ release-critical tests
→ fresh generic physical-iPhone Release archive
→ profile validation
→ widget signing
→ app signing
→ strict codesign verification
→ fresh Payload/IPA
→ IPA identity/provenance verification
→ SHA-256 + manifest + notes
→ immutable GitHub Release targeting the same SHA
```

The workflow does not search old artifacts for an IPA to reuse.

## Release scope lock

`.github/release/iphone-v2-final.json` records the approved V2 scope, included PRs and remaining open PRs that are deliberately outside the freeze.

The final workflow compares that file with GitHub's live open-PR set. Any unreviewed change in the open-PR set fails the release rather than silently expanding or shrinking V2.

## Required signing material

The final workflow requires repository secrets equivalent to:

- `IOS_SIGNING_CERTIFICATE_P12_BASE64`
- `IOS_SIGNING_CERTIFICATE_PASSWORD`
- `IOS_APP_PROVISIONING_PROFILE_BASE64`
- `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`
- `IOS_SIGNING_TEAM_ID`
- `IOS_BUNDLE_ID_PREFIX`
- `IOS_KEYCHAIN_PASSWORD`

Secret values must never be committed or printed.

The profiles must match the expected Team ID, app/widget identifiers and App Group. The application profile must contain the HealthKit capability required by the app.

Missing or incompatible signing material fails the release. An unsigned IPA is not an acceptable fallback.

## iPhone-only release invariants

The source graph and final IPA must establish:

- app and widget `TARGETED_DEVICE_FAMILY = 1`
- no Android product tree or publishing workflow
- no macOS application target or distribution workflow
- no standalone watchOS target or embedded Watch payload
- no universal iPad declaration
- exactly one intended app under `Payload/`
- exactly the intended widget extension
- physical-device `arm64` executable
- correct app/widget bundle identities
- valid embedded profiles
- matching Team ID and App Group
- required HealthKit entitlement
- valid strict app/widget code signatures

An unexpected Watch payload is a release failure. The workflow does not repair the archive by deleting it after the fact.

## Required validation

The release path reruns the release-relevant validation against the exact release SHA, including:

- iPhone-only repository invariants
- iPhone localisation checks
- retained Python/repository verifier tests
- required Swift package tests
- iOS Release compilation
- fresh generic-device archive
- app/widget signing and strict signature verification
- IPA ZIP and structural integrity
- version/build/bundle/device-family identity
- embedded source provenance
- artifact SHA-256 and manifest generation

Normal pull-request CI separately provides broader iPhone-hosted app tests, source hygiene, Linux WHOOP capture/decoder regression tests and Windows decoder regression tests.

## Provenance

The app embeds `NOOPReleaseProvenance.json` before signing. The external release manifest records the same source identity plus artifact identity and checksums.

Required provenance includes:

- repository and `main`
- full and short source SHA
- NOOP 11.8 baseline and baseline SHA
- version and build
- release family
- iOS / iPhone / Release identity
- included PRs and remaining out-of-scope PRs
- artifact filename and SHA-256
- app/widget bundle identifiers and App Group
- relevant embedded-file checksums

If embedded provenance, external manifest, IPA identity and GitHub Release target disagree, publication fails.

## Experimental SpO₂

The release may contain the intentionally retained research tooling, but experimental SpO₂ remains fail-closed and separate from production decisions. Candidate byte `@82` remains unverified unless genuine independent evidence proves otherwise.

Synthetic or structural validation must not be represented as physiological validation.

## Physical-device validation

GitHub-hosted CI does not establish real WHOOP radio behavior, HealthKit authorization prompts, background runtime behavior or physical installation success.

A signed/verified IPA can therefore be release-built while the physical-device checklist is still `NOT YET RUN`. Never convert those items to PASS without real-device evidence.

## Completion rule

Do not describe the final IPA as built and verified unless the signed `.ipa` was freshly produced from the recorded final `main` SHA, passed strict signature and IPA verification, has a recorded SHA-256, and is attached to a GitHub Release targeting that same SHA.

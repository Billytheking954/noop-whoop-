# NOOP fork final iPhone release policy

This repository's final fork release is an **iPhone / iOS IPA built from the exact release commit**. Source-complete, simulator-only, macOS, watchOS and unsigned-placeholder builds are not final releases.

## Canonical identity

- Product: **NOOP**
- Upstream baseline: **NOOP 11.8**
- Recorded baseline commit: `ef0c0d72f2ece1a66c625a30e1076935e584b448` (`Release 11.8.0`)
- Preferred release family: **NOOP V2 — based on NOOP 11.8**
- Numeric Apple version fields remain valid numeric values; fork identity belongs in release metadata, filename, notes and embedded provenance.

## Final artifact

Only the verified iPhone IPA is the application release artifact. The final workflow must not publish separate Android, macOS, watchOS, tvOS, visionOS or simulator application artifacts.

The filename must include the real short Git SHA, for example:

`NOOP-V2-11.8-base-<real-short-sha>-iphone.ipa`

The workflow generates the name from `git rev-parse --short=7 HEAD`; documentation examples must never be substituted for a real SHA.

## Source-to-IPA chain

A release is complete only when this chain is demonstrated:

```text
exact main commit
    -> fresh Release archive
    -> signed iPhone app
    -> freshly packaged IPA
    -> post-package metadata/provenance verification
    -> SHA-256 + release manifest
    -> immutable GitHub release targeting the same SHA
```

The workflow never searches old release assets, build folders or workflow artifacts for an IPA to reuse. It removes its release output directory before building and fails instead of falling back to an older binary.

## Required signing material

The final release workflow is intentionally fail-closed. It requires real iOS signing/provisioning material in GitHub Actions secrets:

- `IOS_SIGNING_CERTIFICATE_P12_BASE64`
- `IOS_SIGNING_CERTIFICATE_PASSWORD`
- `IOS_APP_PROVISIONING_PROFILE_BASE64`
- `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`
- `IOS_SIGNING_TEAM_ID`
- `IOS_BUNDLE_ID_PREFIX`
- `IOS_KEYCHAIN_PASSWORD`

The app and widget provisioning profiles must match the configured bundle identifiers, team, App Group and HealthKit capability. Missing or incompatible signing material stops the release. An unsigned IPA may be useful for development/resigning experiments, but it is not this workflow's final release artifact and must not be presented as one.

## Release scope gate

The dispatch requires the full intended release SHA. It must equal the selected `main` HEAD and descend from the recorded NOOP 11.8 baseline.

Every still-open pull request must also be listed explicitly in the `reviewed_open_prs` dispatch input. The workflow compares that list with GitHub's live open-PR set and stops on any mismatch. This is deliberately awkward: it forces a human to confirm that work remaining on another branch is genuinely outside the release scope instead of silently forgetting it.

## Required validation

Before publication the final workflow runs or verifies:

- source hygiene and protocol-document examples
- i18n coverage
- portable Python regression suites on Linux and Windows
- Swift package builds/tests
- iOS Simulator compilation
- shared app unit tests
- a fresh generic-device **Release** archive
- iPhone-only device-family metadata
- removal of embedded watch payload from the final IPA
- app and widget signing/provisioning
- code-signature verification
- IPA ZIP integrity
- app/widget bundle identifier, version and build number
- embedded exact Git SHA and NOOP 11.8 provenance
- arm64 device architecture and rejection of simulator architectures
- SHA-256 generation
- final release manifest
- release notes generated after the verified build from the source/merge history actually included

A physical iPhone is not attached to a GitHub-hosted runner. The release notes must therefore state that physical install/launch smoke testing was **not performed** unless a real device test is separately added and succeeds.

## Release manifest

The manifest shipped alongside the IPA records at least:

- product and release family
- upstream baseline and baseline SHA
- repository and branch
- full and short release SHA
- app version and build number
- Release configuration and Xcode target
- platform and device family
- included merged PR numbers
- open PRs reviewed as outside scope
- artifact filename
- artifact SHA-256
- build date
- signing identity description
- physical-device-test status

A smaller provenance document containing the immutable source identity is also embedded inside the app **before signing**, allowing an extracted IPA to be traced back to its source even if the external manifest is separated from it.

## Release notes

Notes are produced after the final IPA has passed verification. They include:

- exact release identity
- merged changes actually reachable from the 11.8 baseline
- why the significant change groups exist
- deliberately unchanged production behaviour where verified
- experimental/research boundaries
- genuine known limitations
- the validation steps that actually passed
- anything explicitly not performed

No validation item receives a check mark merely because it was intended to run.

## Final completion rule

Do not state that the final IPA is ready unless the signed `.ipa` exists, was freshly built from the recorded commit, passed post-package verification, has a recorded SHA-256, and is attached to the GitHub release targeting that same commit.

# NOOP V2 scope and non-goals

NOOP V2 is an iPhone-only, local-first companion for a user's own wearable data. The supported application product is the iPhone app plus its required widget extension.

## Hard product constraints

- iPhone is the only supported end-user application platform in this fork.
- Data and scoring remain local-first.
- NOOP V2 is not a medical device.
- Experimental physiological decoding stays instrumentation until independently validated.
- Production scoring must not change silently because research tooling exists beside it.
- A formal release must be traceable to the exact source SHA that produced its signed IPA.

## In scope

- WHOOP BLE scanning, pairing, reconnect and history synchronization on iPhone
- local persistence, import/export and diagnostics
- Recovery, Strain, Sleep, Stress and workouts using the approved production implementation
- HealthKit interoperability and canonical health-evidence work intentionally included in V2
- Night Lab capture, sealed evidence, deterministic replay, inspection and evidence-quality tooling
- required iPhone widgets / Live Activities
- research/capture tools that help validate the iPhone product or wearable evidence
- experimental SpO₂ instrumentation that remains visibly experimental and outside production decisions

## Out of scope for V2

- Android application/product support
- macOS application/product support
- standalone watchOS product support
- universal iPad product support
- restoring cross-platform Swift/Kotlin parity obligations
- unrelated V3 features or speculative architectural rewrites
- production promotion of unverified SpO₂
- clinical claims, diagnostic alerts or medical-device behavior
- merging an open research or scoring PR merely to make the release ledger look tidy

## Production safety boundary

Unless a reviewed change explicitly states otherwise, V2 preserves established behavior for:

- Recovery
- Strain
- Sleep score and production staging
- Stress scoring
- HRV and resting heart rate semantics
- respiration
- workouts
- WHOOP BLE operation
- database semantics
- production HealthKit reads/writes

Experimental SpO₂ is not a production HealthKit write or scoring input.

## Research boundary

Research code may live in the repository or app when intentionally retained, but it must remain distinguishable from trusted production behavior.

For new physiological candidates, require evidence appropriate to the claim. A parser accepting bytes or a synthetic fixture matching expected numbers does not establish physiological identity.

Candidate SpO₂ byte `@82` remains unverified unless independent aligned reference data demonstrates otherwise.

## Network behavior

Local-first does not mean the app can never use a network connection. Any optional network behavior must be explicit, user-controlled where appropriate, documented, and unable to become a hidden dependency for core wearable collection or scoring.

Do not introduce a NOOP-operated account/cloud requirement into V2 without an explicit future scope decision.

## Scope changes

A future platform or production-model expansion should be a deliberate project decision with its own review and tests. It should not arrive accidentally through a shared package, stale upstream workflow, or old documentation.

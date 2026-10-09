# NOOP V2 — Work Checkpoint

**Updated:** 9 October 2026  
**Status:** PARTIALLY VERIFIED — PR #40 validated and unsigned IPA recovered; Figma approval phase remains blocked by Figma MCP capacity.

## Scope

This checkpoint tracks the Apple-native UI redesign work and the independently scoped Sleep / Night Map delivery.

- Design-system documentation PR: #41
- Sleep / Night Map implementation PR: #40
- Production branch: `main` (unchanged)

## Completed design work

- Audited the existing Figma file and documented the gaps between its exploratory screens and an implementation-ready system.
- Created Figma variable collections for spacing, radius, primitive colors, semantic light/dark colors, metric colors, and sleep-stage colors.
- Created reusable design documentation:
  - `docs/design/NOOP_APPLE_DESIGN_SKILL.md`
  - `docs/design/NOOP_PRECISION_TOKEN_SPEC.md`
- Created this handoff checkpoint.

## Figma blocker

The Figma MCP Starter-plan call limit was reached after the foundation variables were created.

Not yet completed:

1. Three fully composed design directions
2. Direction selection / approval checkpoint
3. Figma component library and screen rebuild
4. App-wide SwiftUI implementation

No visual direction has been represented as approved.

## Exact-head Sleep / Night Map validation

PR #40 was validated at its exact source commit:

- Branch: `feature/sleep-night-map-clinical-20261009`
- Source SHA: `d64b2c012052e9408f16dc1adac38ebf07391ffd`
- Version / build: `12.0.0 (435)`

All required GitHub Actions runs succeeded:

- iPhone i18n Coverage: `37923838661`
- Source Hygiene: `37923838733`
- Tools Python CI: `37923838688`
- App build (iPhone): `37923838686` — simulator build, iPhone-hosted tests, and seeded screenshot capture passed
- Unsigned iPhone sideload IPA: `37923838682` — archive/package verification passed

Recovered release artifact:

- Artifact ID: `11613348386`
- IPA: `NOOP-V2-12.0-base-d64b2c012052-iphone-unsigned.ipa`
- Verified SHA-256: `d23ce2e42adc5a5a01ad12a97e6bfca50385478922f385f828f0cd2a70ff665b`

The IPA archive integrity passed and includes `Payload/NOOP.app`, `NOOPWidgets.appex`, and `NOOPReleaseProvenance.json`.

## Required next actions

1. Re-sign the exact verified IPA with iLoader, SideStore, or AltStore and test the Night Map flow on a physical iPhone.
2. Verify the user-visible empty/error states and real HealthKit/BLE behaviour; CI cannot replace physical-device entitlement validation.
3. Keep PR #40 as a draft until that review is complete.
4. When Figma capacity is restored, compose the three design directions, request explicit approval of one, then begin the app-wide SwiftUI redesign.
5. Do not merge the documentation or implementation work into `main` without the required reviews.

## Guardrails

- Do not alter production scoring, recovery, HealthKit/BLE contracts, authorization behaviour, or existing app flows while completing the visual redesign.
- Do not fabricate sleep-stage data or claim a physical device test that has not occurred.

# NOOP 12 / V2 Integration Status

This ledger is the recovery source for the `integration/noop12-v2` effort. Actual Git state takes precedence if it conflicts with this document.

## Verified baseline

- Starting fork `main`: `b72518f5cafe0b5ac0bec0e1bea71ae42cd403f9`
- Upstream NOOP `v12.0.0`: `7acce06c3d22cb5dfe959f2c4a43902471d21332`
- Merge base: `ef0c0d72f2ece1a66c625a30e1076935e584b448`
- Ahead/behind at start: fork has 125 unique commits; upstream tag has 359 unique commits
- Integration branch: `integration/noop12-v2`
- PR #34 head: `f7443069d9c4a5a00023f754b5e93078219eda88` (open draft)
- PR #35 head: `d3c5273f3a52b46d2ae03865e3d582e9d788ccc3` (closed, not merged)

## Phase status

- Phase 0 — initial truth and local recovery branch: completed locally; remote push blocked
- Phase 1 — recoverable integration baseline: completed locally at `8810e53ab9581b32eef4e2e9accc83a56a8ff58a`
- Phase 2 — exact upstream `v12.0.0` integration: completed locally at `878429706c5366baffff8c9c7bb8fc6c383721ff`
- Phase 3 — duplicate/PR consolidation: completed locally; remote PR cleanup blocked by GitHub authentication
- Phase 4 — reliability core: useful PR #35 primitives and production HR-gap guard retained; duplicate headless persistence/provenance stores removed in favor of canonical app/store implementations
- Phase 5 — V2 iPhone UI: completed locally at `8739e662f438a45af85410921cf4d39845c1ea30`
- Phase 6 — full validation and IPA: all locally executable gates pass; IPA blocked by the absence of macOS/Xcode, signing assets, and a pushable SHA
- Phase 7 — final audit: completed locally; remote branch/PR cleanup and physical-hardware checks remain external

## Architecture decisions

- The release product remains iPhone-only: `NOOPiOS` plus `NOOPiOSWidgets`.
- Upstream integration is pinned to the exact `v12.0.0` tag, not upstream `main`.
- Night Lab, sealed evidence, deterministic replay, provenance, and canonical HealthKit safety remain product invariants.
- Experimental SpO2 remains isolated from production Recovery, Strain, sleep, HealthKit writes, and recommendations.
- Existing fork production algorithms are not automatically preferred; sleep/analytics conflicts require evidence-based canonical selection.
- The exact upstream tag was merged while retaining the fork's iPhone-only scope: incoming Android, standalone watch, macOS-root, and cross-platform parity-governance product files remain deleted.
- Upstream 12 production analytics/sleep/protocol changes were accepted where Git could combine them without a semantic conflict; Night Lab and fork-only evidence packages remain present. Swift test confirmation is still required.
- The responsive V2 three-ring hero was retained; the upstream 12 score-dependent Charge tint and new navigation dependency were incorporated.
- Release identity is now NOOP V2 / upstream NOOP 12.0.0 / app 12.0.0 / build 435. Both unsigned and signed workflows are pinned to tag commit `7acce06c3d22cb5dfe959f2c4a43902471d21332`.
- The iPhone localisation backlog is explicitly re-baselined at 306 existing literals (0 Android entries). This makes the regression gate pass but is not a claim that those literals were translated.
- PR #35's duplicate headless persistence actors were removed. Existing `ActiveWorkoutPersistence`, route/lift persistence, and transactional `WhoopStore` score-input provenance remain the canonical production systems.
- PR #34's final reference UI stack is integrated with NOOP 12 rather than replacing the 12.0 core wholesale. The reference ring token is increased from 4 pt to 6 pt for the requested slightly thicker rings.
- HealthKit conflict resolution preserves pre-read fail-closed behavior, save-before-retire replacement, exact-object legacy retirement, open-night withholding, stable keys, and genuine-SDNN-only writes.

## Early iPhone / IPA feasibility

- Source configuration declares iOS 17, scheme `NOOPiOS`, app and widget `TARGETED_DEVICE_FAMILY = 1`, configurable bundle prefix, HealthKit app entitlement, and shared App Group.
- `.github/workflows/iphone-sideload-ipa.yml` has a credible generic physical-iOS unsigned build path and validates arm64, app/widget identity, device family, Payload structure, absence of Watch payload, and exact source provenance.
- `.github/workflows/iphone-final-release.yml` has a signed archive path with profile, entitlement, identity, signature, structure, and provenance checks.
- This local Work runner is Linux and has neither Xcode/XcodeGen nor Swift, so it cannot execute an iPhone compile/archive locally.
- GitHub workflow dispatch and macOS build evidence are unavailable until the branch can be pushed or GitHub write authentication is supplied.

## Validation evidence

PASS:

- `python3 Tools/verify_iphone_only_repo.py`
- `python3 -m unittest -v Tools.test_verify_iphone_ipa` (4 tests)
- `python3 -m unittest discover -s Tools -p 'test_*.py' -v` (36 tests after retiring Android/parity-only suites)
- `python3 Tools/doc_comment_lint.py`
- `python3 docs/protocol-examples/validate_examples.py`
- `python3 docs/protocol-examples/check_source_references.py` (88 references, 0 failures)
- `python3 Tools/i18n_ios_ci.py` (306 known baselined literals; focus locales complete and format-safe)
- `python3 -m unittest discover -s Tools/linux-capture -p 'test_*.py' -v` (276 passed, 1 expected skip: no real capture database)
- Workflow YAML parse with PyYAML (all workflow files)
- Post-integration release audit at `1ea0e265e795fd301e42447f28013a91ea10c735`: exact-v12 and PR #34 ancestry, clean tree, no merge markers, `git fsck`, iPhone-only, localisation, docs/protocol, 36 repository/tool, and 276 capture tests all pass. A stale contributor-facing NOOP 11.8 baseline reference was corrected to 12.0.0.
- Release-documentation follow-up: `UNSIGNED_IPA_BUILD_PLAN.md` is now explicitly archived/pre-v12 and points to the v12 build/release workflows, preventing an exploratory unsigned IPA recipe from being mistaken for the current release procedure.

FAIL:

- None in the locally executable post-merge gates.

NOT RUN / EXTERNAL:

- Swift package tests: Swift toolchain unavailable locally.
- Xcode project generation, iPhone compilation, hosted tests, device archive, and IPA packaging: macOS/Xcode unavailable locally.
- Physical WHOOP, HealthKit, background, overnight, and restart validation: hardware required.

## PR / supersession audit

Current classification:

- PR #2 and #3: keep out of this release pending independent stress/ScoreBench evidence review.
- PR #4: experimental Night Lab Phase 2; Night Lab foundation remains, production sleep is unchanged by this PR.
- PR #25, #26, #27: safety/FIT work is superseded or selectively incorporated through the later PR #34 stack and the NOOP 12 integration; do not mechanically merge.
- PR #28, #30, #31, #32, #33: superseded by the final PR #34 stack now integrated.
- PR #29: remains experimental SpO2 research only; not promoted into production scoring or HealthKit.
- PR #34: integrated with manual NOOP 12 conflict resolution.
- PR #35: useful reliability primitives and the production missing-HR guard are ported; duplicate persistence/provenance actors were removed where canonical production systems already exist.

## External blockers

- First push failed with `could not read Username for 'https://github.com': No such device or address`; no GitHub write credential is configured in this runner.
- No GitHub CLI is installed.
- No Xcode/macOS runner is available locally.
- No Apple signing certificate or provisioning profiles are available locally.

## Recovery footer

LAST VERIFIED REMOTE SHA:
`none — integration branch has not been pushed because GitHub authentication is unavailable`

LAST VERIFIED STATE:
`Fork main and exact upstream v12.0.0 verified; local integration branch created; baseline source/release feasibility inspected.`

CURRENT LOCAL SHA:
`HEAD` (resolve with `git rev-parse HEAD`); last non-ledger checkpoint: `c99e2acc9ebc3c508ce82277bbcc30e01bf762e0`

TESTS PASSING:
`iPhone-only verifier; IPA verifier (4); retained Tools suite (36); Linux capture suite (276 pass, 1 expected skip); doc-comment lint; protocol arithmetic/source references; iPhone localisation regression/focus-locale gate; workflow YAML parse`

KNOWN FAILURES:
`No locally executable red gate; 306 existing iPhone UI literals remain as explicit localisation debt; Swift/Xcode compile not executable here`

EXTERNAL/HARDWARE BLOCKERS:
`GitHub write authentication; macOS/Xcode/Swift toolchain; Apple signing assets; physical iPhone and WHOOP hardware`

IPA STATUS:
`NOOP 12.0.0 source pipeline is structurally credible; no new exact-SHA physical-device artifact has been built in this Linux runner.`

NEXT EXACT ACTION:
`Push integration/noop12-v2 from an authenticated GitHub environment, open the integration PR, confirm app-build.yml succeeds on the exact PR head, merge the reviewed branch to main, then run the pinned macOS signed/unsigned IPA workflows and physical-iPhone smoke checks.`

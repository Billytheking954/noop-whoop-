# Repository audit — 18 September 2026

## Scope and starting point

Audited `Billytheking954/noop-whoop-` from integrated `main`
`77516fc407db4a78e1496a5456b1741598658250` (NOOP 11.8 plus Night Lab).
The pass combines repository-wide portable checks with focused review of the recently
integrated archive and experimental evidence boundaries. It is not a claim that every
platform, runtime path, or hardware interaction has been exercised.

## Prioritised findings and changes

| Priority | Root cause / effect | Resolution |
| --- | --- | --- |
| High | Integration omitted existing SpO2 hardening: extra frame bytes were silently ignored, public sample construction bypassed numeric checks, and repeated/overlapping epochs could inflate evidence. | Applied the relevant source and regression-test changes from `fix/spo2-evidence-validation` at `4eb63f2`. Enforce exact frame length, finite consistent sample values, unique non-overlapping epochs, accepted interval coverage, matching windows and contiguous stage evidence. |
| High | Night Lab subtracted arbitrary signed timestamps and converted large floating-point expected counts directly to `Int`. Malformed imported windows or extreme cadence could trap instead of returning a validation result. | Validate manifest duration with checked subtraction; both coverage helpers return unavailable coverage for unrepresentable windows/counts. Added five tests covering both integer extremes, reversed/empty windows, NaN, infinity and finite overflow. |
| High | Direct archive APIs lacked some of the path checks already used by inspection. A matching digest alone did not prevent reading a symlink target, and a mismatched manifest could authorize operations on the requested directory. | Reuse path isolation for creation, import publication, raw/derived reads and writes; validate IDs, manifest identity and structure on direct loads. Added traversal, identity-mismatch, symlinked raw-file and symlinked archive-parent regression scenarios. |
| Medium | The integrated Python comparison tool ignored timezone offsets and conflated missing fields, recorded zeros and non-overlapping reference windows. Backup reads lacked the existing integrity preflight. | Applied existing backup-validation and comparison fixes plus their tests. Require read-only, standalone, integrity-checked SQLite; bounded canonical backup extraction; explicit offsets; distinct missing/no-overlap results; RMSE and median absolute error. Added annotations to the restored backup helper. |
| Medium | Two parity acceptance tests failed because the stored inventory still described the pre-integration source tree. | Refresh derived authority with the documented guarded migration against the exact integrated base. No typed dispositions, pair declarations or exemption rules are changed. The report retains the existing one-sided Night Lab research debt; this is not a claim of Android feature parity. |
| Medium | Python CI's `Tools/**` filter skipped changes to Swift/Kotlin sources and catalogues consumed by its tests. | Remove the core workflow's path filters and update its contract test. The expensive parity workflow remains scoped. Core Linux and Windows tests now also run on product-only changes. |
| Low | Diagnostics presented an unverified summary-frame layout too confidently. | Restore the existing experimental-hypothesis wording. |

## Validation

- Baseline capture suite: 234 tests, one skipped, no failures.
- Baseline Tools suite: 271 tests, two failures (both stale parity metadata).
- Updated capture suite: 248 tests, one skipped, no failures.
- Updated Tools suite: 281 tests, no failures.
- Guarded authority migration passed its embedded offline parity ratchet against
  `77516fc4`; 310 existing findings remain recorded. The stale base requires the
  explicit `--migrate-authority` comparison mode until this metadata repair lands.
- Python compilation, source-hygiene gate, localisation gate and whitespace checks pass.
- Tracked-file scan: 56 Python sources parsed; 72 JSON/catalogue files parsed; nine shell
  scripts passed `bash -n`; all 13 local Swift package dependency paths resolved.
- Eight new Swift test methods cover the newly added numeric and archive-path guards.
  Additional existing SpO2 regression methods were brought forward with their fixes.

The source branch `4eb63f2` has successful Swift Packages CI run `35239522110`.
That is supporting evidence for reused code, **not validation of this integrated audit head**.
This Linux workspace has no Swift/Xcode installation. Android unit tests were attempted,
but the uncached Gradle 8.7 distribution could not download (`Network is unreachable`).
The audit head still needs its own Swift package and macOS/iOS app CI results.

Reproduction commands:

```sh
python3 -m unittest discover -s Tools/linux-capture -p 'test_*.py'
python3 -m unittest discover -s Tools -p 'test_*.py'
python3 -m compileall -q Tools
python3 Tools/doc_comment_lint.py
python3 Tools/i18n_audit.py --ci origin/main
python3 Tools/parity_ledger.py
python3 Tools/parity_ratchet.py --base origin/main --offline --migrate-authority
git diff --check
```

The metadata repair uses the existing documented command:

```sh
python3 Tools/parity_ledger.py --refresh-derived --migrate-authority --base origin/main
```

## Remaining validation and feature boundaries

1. Require passing Swift package and macOS/iOS app CI for the published audit head,
   including the new archive regressions; rerun Android on a provisioned runner if
   Android validation is required for release. No Android source changed in this pass.
2. Validate BLE lifecycle on real hardware before any release claim. This pass changes
   no commands, pairing ownership, acknowledgement behaviour or firmware behaviour.
3. SpO2 remains experimental and diagnostically isolated. Synthetic passing tests do
   not prove the proposed packet exists on hardware or measures blood oxygen accurately.
   Official WHOOP and NOOP cannot both offload the identical historical night; validation
   planning must respect that ownership constraint. No SpO2 promotion is made here.
4. Existing ScoreBench, causal stress and Phase 2 sleep-detection work remains on its
   own branches. Their review history is preserved; they are not silently merged as
   missing features during an audit.
5. Archive checks protect against malformed input and existing symlinks. They do not
   claim resistance to a hostile concurrent process replacing filesystem entries between
   checks. Cross-process archive lifecycle locking and bounded bundle-memory usage need
   separate design and tests if that threat/resource model becomes a requirement.

Production sleep/recovery/scoring coefficients, database migrations, stored physiological
values and HealthKit writes are unchanged. The modified Swift APIs belong to the existing
research-only Night Lab/summary-frame layer, which has no shipped Kotlin counterpart.

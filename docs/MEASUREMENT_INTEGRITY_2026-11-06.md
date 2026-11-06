# HealthKit sleep import integrity candidate

This candidate starts at Ryan's NOOP v12.0.0, commit
`7acce06c3d22cb5dfe959f2c4a43902471d21332`. It corrects specific data-handling
and provenance errors. It does not change sleep-detection or sleep-staging coefficients,
and does not claim improved physiological staging, recovery, or sleep scheduling.

## Pre-test acceptance criteria

Recorded before executing the new regression suites. Inputs are synthetic interval and
SQLite fixtures, not a person's health data. Acceptance requires all cases to pass.

- Sixty minutes of unspecified sleep yields sixty asleep and absent stage totals.
- Duplicate and overlapping same-stage records count their union once within a day bucket.
- An unspecified overlay does not double-count or erase explicit stages.
- Contradictory explicit stages keep the observed sleep total but withhold the breakdown.
- Awake/asleep contradictions withhold the sleep total and stage breakdown.
- Gaps remain gaps; no synthetic stage transitions or sleep sessions are created.
- Invalid timestamps are rejected. Source review checks that failed HealthKit reads
  hold the import write; the package fixtures do not execute HealthKit callbacks.
- Corrected missing stages remove stale live sleep chart points for affected days.
- Replacement rejects invalid scope and rolls back on insertion failure; unrelated sources,
  dates, metrics and file-imported awake/in-bed points remain intact.
- The capability table classifies calculated metrics using its existing estimate legend.

The pure resolver belongs to StrandImport but is initially used only by iOS's live
HealthKit adapter. Health Connect and XML export ingestion are separate paths and have
not been claimed corrected. The UI classification change is mirrored on Android.

## Scope limits

The live adapter retains existing attribution by each record's end date. It resolves
overlaps within those buckets; it does not reconstruct full sleep sessions, resolve
overlaps assigned to different dates, or establish historical timezone correctness.
It cannot read Health app source-priority preferences and does not guess a preferred
vendor. Missing/contradictory stage evidence is withheld rather than reconstructed.
Successful reads are not proof of HealthKit read permission: Apple's privacy behaviour
can make permission-denied reads appear empty.

The existing multi-step import is not an all-metrics transaction. Daily metric rows
and their sleep-series replacement share a transaction; a later failed import stage
still requires retry.
Deletion reconciliation for days absent from every queried metric remains separate work.

No user database is opened by this work. Before installing this clean baseline over
existing V2, its v48/v49 compatibility, backup and restore protections still need to be
ported and tested. This is a development branch, not an installation-ready release.

## Validation commands

The candidate workflow checks out the pushed commit directly, without merging the
existing fork's main branch:

```
cd Packages/StrandImport && swift test
cd Packages/WhoopStore && swift test
xcodegen generate
xcodebuild -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -scheme Strand -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
python3 Tools/doc_comment_lint.py
```

Package tests check synthetic accounting and persistence. App compilation checks that
the production adapter is integrated. Neither is a physical HealthKit permission test,
an overnight WHOOP capture, or a PSG benchmark. No accuracy percentage is inferred.

## HRV review qualification

The earlier council review treated the Today mixed-method stopgap comment as evidence
of active Apple SDNN contamination. A deeper trace found that this upstream refresh
path keeps Apple rows separate from `repo.days`. The comment alone does not demonstrate
that production route. Method/source tracing remains open; this candidate does not
claim to fix it or infer a measurement method from numeric magnitude.

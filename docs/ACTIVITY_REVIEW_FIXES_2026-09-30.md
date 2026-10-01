# Activity review follow-up — 2026-09-30

## Confirmed gaps and fixes

- `saveManualWorkout` swallowed SQLite failures, and `saveDetectedWorkout` returned success anyway. The card could disappear without a saved workout. Manual persistence now returns a durable-save result, which the suggestion path propagates.
- Editing a suggestion recorded its dismissal even when its replacement failed to save. `saveEditedDetectedWorkout` now gates dismissal on successful persistence, including when the edit moves outside the original interval.
- Dismissing the newest suggestion hid the whole card until a later data refresh. Save and dismissal now explicitly request another scan, independently of whether `refreshSeq` changes, revealing the next eligible interval. Dismiss controls are disabled during a write, and superseded scans cannot replace the card during that write. The edit sheet holds the originally selected interval even if a sync changes the card behind it.

The detector thresholds, production scores, exact-span dismissal compatibility and two-day scan window are unchanged. This is sequential review of existing detector results, not a new persistent candidate-history system. Dismissals remain durable in the existing preference store, and suggestions can be re-derived from stored HR after restarting.

## Validation

Added iPhone-hosted regressions that inject a real SQLite rejection trigger, verify direct and edited saves report failure without a dismissal, then retry successfully. A separate two-activity fixture verifies newest-first review, durable dismissal across repository reconstruction, saving the next activity, and no remaining suggestion.

Local checks passed: iPhone-only repository invariants, detached-doc-comment lint, and `git diff --check`. This Linux workspace has no Swift/Xcode toolchain; iPhone compilation and hosted tests require the draft PR's App build workflow. CI status is reported on the PR rather than assumed here.

## Scope and remaining work

This follow-up is based on PR #32 and requires that integration. No merge, signing or release is performed. Persistent multi-candidate review history, minute-level Effort presentation, and physical-device activity validation remain development gaps. Experimental SpO2 stays isolated and the formal release freeze is unchanged.

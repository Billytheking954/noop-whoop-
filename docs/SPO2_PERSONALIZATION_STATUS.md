# WHOOP 5 SpO2 investigation

## Findings

The decoder already exposes the v18 frame byte at absolute offset 82 as
`spo2_candidate_82` when its value falls in 70–100. Its source comments document
contradictory validation across devices. This is a candidate field, not a verified
oxygen measurement. The app banks the underlying byte in `v18AuxSample`; the
existing `Tools/linux-capture/validate_spo2_candidate.py` can read that database.
No new sensor command or speculative percentage formula is required to start.

The existing validator documents intermittent emission windows. A sparse capture
can miss those windows. Zero, missing, out-of-band codes, and an in-band candidate
must therefore remain distinguishable. No claim about this wearer's actual data
is possible until a database or capture is provided.

## Changes

* Preserve missing/undecodable byte 82 as `None` rather than zero.
* Count only observed byte values in duty-cycle fractions and absence evidence.
* Do not count a missing field as coverage of a sampling window.
* Report missing-record counts and an unknown duty mode when nothing was observed.
* Convert explicit timestamp offsets and `Cycle timezone` offsets to UTC before
  comparing WHOOP export windows with the strap's Unix timestamps.

The prior timezone comment was incorrect: interpreting local wall time as UTC does
not cancel the offset against a sensor timestamp that is already UTC. Naive
timestamps without any timezone metadata retain the legacy UTC assumption for
compatibility; confirm that assumption before using such an export. Unrecognised
explicit cycle offsets are rejected by the timestamp parser.

Tests: 52 existing tests passed before changes; 60 passed afterwards, including
eight new regressions for missing stored fields, corrupt blobs, coverage,
nonzero fractions, and timezone conversion. Fixtures are synthetic. No personal
night was evaluated, and no app build or physiological validation was performed.
These are Python validation-tool changes only; Swift/Kotlin algorithms and
displayed metrics are unchanged.

## Data needed next

Use a consistent standalone copy of the NOOP app database, plus the official WHOOP
export ZIP containing `physiological_cycles.csv` for overlapping nights. Keep both
private. That export can supply `Blood oxygen %` when available; if absent, use
dated official-app readings as an explicitly manual external reference.

Run the existing validator locally from `Tools/linux-capture`:

```sh
python validate_spo2_candidate.py /private/noop.sqlite /private/whoop-export.zip --device trial-band --show-nights
```

If several devices are stored, use its `--app-device` argument to select the
physical strap. Do not pool identities. Inspect missing fields, recorded zeroes,
in-band candidates, sleep-state coverage, and sampling windows before interpreting
agreement. A missing field can also result from schema/codec mismatch or retention.

Compare several ordinary nights and reserve later nights for testing. Matching
WHOOP supports interoperability; it does not establish clinical accuracy. Constant
values near the usual range cannot establish tracking ability. Do not promote the
candidate to the health metric or write it to Apple Health until evidence resolves
the existing contradictions. The validator's promotion checklist is a research
screen, not certification. No change to oxygen levels or unusual breathing is
needed for this investigation.

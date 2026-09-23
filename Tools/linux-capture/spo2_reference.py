#!/usr/bin/env python3
"""Inspect retained @82 evidence and compare an independent oximeter recording.

Offline research only. WHOOP 5 history has one consumer: this workflow reads a
NOOP-owned exported database/backup and never requires a second app to offload it.
No decoder identity, calibration, production measurement or promotion is inferred.
See docs/SPO2_REFERENCE_WORKFLOW.md for the deliberately strict input contract.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
import sys
from datetime import datetime
from pathlib import Path
from typing import Mapping, Sequence

import validate_spo2_candidate as candidate
from backup_validation import open_verified_database, snapshot_path
from capture_io import configure_utf8_stdio

METHOD = "v18-at82-independent-exact-second-v2"
MIN_MATCHED_FRACTION = 0.80  # Research completeness policy, not physiological validity.
MIN_PAIRED_SECONDS = 2  # Mathematical floor for a paired comparison; not a validation threshold.
UINT32_MAX = 2**32 - 1


def timestamp(raw: str) -> int:
    """Whole Unix seconds or ISO 8601 with an explicit offset; never guess a zone."""
    raw = raw.strip()
    try:
        if raw.isascii() and raw.isdigit():
            value = int(raw)
        else:
            date = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            if date.tzinfo is None or date.utcoffset() is None or date.microsecond:
                raise ValueError
            utc_seconds = date.timestamp()
            if not utc_seconds.is_integer():
                raise ValueError
            value = int(utc_seconds)
        if not 0 <= value <= UINT32_MAX:
            raise ValueError
        return value
    except (ValueError, OverflowError, OSError) as error:
        raise ValueError("Timestamps require whole Unix seconds or ISO 8601 with a timezone offset") from error


def read_metadata(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as source:
        metadata = json.load(source)
    if not isinstance(metadata, dict):
        raise ValueError("Reference metadata must be a JSON object")
    if metadata.get("reference_kind") != "independent_oximeter":
        raise ValueError("Reference must be an independent oximeter, not WHOOP or NOOP output")
    if metadata.get("same_wearer") is not True:
        raise ValueError("Reference metadata must explicitly attest the same wearer")
    for key in ("reference_device", "reference_firmware", "capture_device_model",
                "capture_firmware", "clock_alignment_note"):
        if not isinstance(metadata.get(key), str) or not metadata[key].strip():
            raise ValueError(f"Reference metadata requires {key}; use 'unknown' only for unknown firmware")
    if metadata.get("partition") not in ("development", "holdout"):
        raise ValueError("Declare the development/holdout partition before comparing values")
    offset = metadata.get("clock_offset_seconds")
    if type(offset) is not int or abs(offset) > 300:
        raise ValueError("Declare a measured whole-second clock offset within +/-300 seconds")
    return metadata


def read_reference(path: Path, *, clock_offset_seconds: int) -> tuple[dict[int, float], dict]:
    """Deduplicate logged samples; reject contradictory values or quality at one time.

    Offset convention: aligned timestamp = reference timestamp + declared offset.
    No nearest-neighbour matching, rounding, interpolation or carry-forward exists.
    """
    samples: dict[int, tuple[bool, float | None]] = {}
    counts = {"rows": 0, "duplicates": 0, "invalid_quality": 0}
    with path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != ["timestamp", "spo2_percent", "quality"]:
            raise ValueError("Reference CSV columns must be timestamp,spo2_percent,quality")
        for row_number, row in enumerate(reader, start=2):
            counts["rows"] += 1
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"Malformed reference CSV row {row_number}")
            ts = timestamp(row["timestamp"]) + clock_offset_seconds
            if not 0 <= ts <= UINT32_MAX:
                raise ValueError(f"Aligned reference timestamp out of range at row {row_number}")
            quality = row["quality"].strip().lower()
            if quality not in ("valid", "invalid"):
                raise ValueError(f"Reference quality must be valid/invalid at row {row_number}")
            value = None
            if quality == "valid":
                try:
                    value = float(row["spo2_percent"])
                except ValueError as error:
                    raise ValueError(f"Invalid reference percentage at row {row_number}") from error
                # Do not discard low reference values just because the @82 candidate
                # uses a 70..100 exploratory range. That would hide disagreement.
                if not math.isfinite(value) or not 0 < value <= 100:
                    raise ValueError(f"Invalid reference percentage at row {row_number}")
            observation = (quality == "valid", value)
            if ts in samples:
                if samples[ts] != observation:
                    raise ValueError("Conflicting reference observations at the same timestamp")
                counts["duplicates"] += 1
            else:
                samples[ts] = observation
    counts["invalid_quality"] = sum(not valid for valid, _ in samples.values())
    valid_samples = {ts: value for ts, (valid, value) in samples.items() if valid and value is not None}
    counts["valid_seconds"] = len(valid_samples)
    return valid_samples, counts


def metrics(pairs: Sequence[tuple[float, float]]) -> dict | None:
    if not pairs:
        return None
    values, references = zip(*pairs)
    errors = [value - reference for value, reference in pairs]
    return {
        "count": len(pairs),
        "candidate_minus_reference_mean": statistics.fmean(errors),
        "mean_absolute_difference": statistics.fmean(abs(error) for error in errors),
        "median_absolute_difference": statistics.median(abs(error) for error in errors),
        "root_mean_squared_difference": math.sqrt(statistics.fmean(error**2 for error in errors)),
        "pearson_r": candidate.pearson_r(values, references),
    }


def analyze(records: Sequence[dict], start: int, end: int,
            reference: Mapping[int, float] | None = None) -> dict:
    if type(start) is not int or type(end) is not int or not 0 <= start < end <= UINT32_MAX:
        raise ValueError("Use a nonempty half-open window within the WHOOP timestamp range")
    # An exported store normally enforces one row per device/second. Keep the pure
    # analysis deterministic and fail closed if a caller supplies contradictory rows.
    observed: dict[int, tuple[int | None, int | None]] = {}
    duplicates = 0
    for record in records:
        ts = record.get("unix")
        if type(ts) is not int or not 0 <= ts <= UINT32_MAX:
            raise ValueError("Invalid NOOP record timestamp")
        if not start <= ts < end:
            continue
        raw = record.get("aux_byte_82")
        state = record.get("sleep_state")
        if raw is not None and (type(raw) is not int or not 0 <= raw <= 255):
            raise ValueError("Invalid raw @82 byte")
        if state is not None and (type(state) is not int or not 0 <= state <= 3):
            raise ValueError("Invalid strap sleep-state code")
        sample = (raw, state)
        if ts in observed:
            if observed[ts] != sample:
                raise ValueError("Conflicting NOOP observations at the same timestamp")
            duplicates += 1
        else:
            observed[ts] = sample
    stamps = sorted(observed)
    # Every retained row witnesses one second, not the entire gap to the next row.
    gaps = [stamps[0] - start, end - stamps[-1] - 1] if stamps else [end - start]
    gaps.extend(right - left - 1 for left, right in zip(stamps, stamps[1:]))

    # IMPORTANT: do not pre-filter comparison evidence to the hypothesised 70..100
    # range. A nonzero asleep value outside that range is evidence *against* the
    # direct-percent interpretation and must remain in the denominator and pairs.
    comparison_candidates = {
        ts: raw for ts, (raw, state) in observed.items()
        if raw is not None and raw != 0 and state == candidate.SLEEP_ASLEEP
    }
    inband_candidates = {
        ts: raw for ts, raw in comparison_candidates.items() if raw in candidate.INBAND
    }
    asleep_out_of_band = {
        ts: raw for ts, raw in comparison_candidates.items() if raw not in candidate.INBAND
    }

    result = {
        "method": METHOD,
        "evidence_status": "experimental_unvalidated",
        "promotion_allowed": False,
        "candidate_range_consistent": not asleep_out_of_band,
        "window": {"start_unix": start, "end_unix_exclusive": end},
        "observations": {
            "retained_seconds": len(observed),
            "retained_fraction": len(observed) / (end - start),
            "largest_missing_gap_seconds": max(gaps),
            "duplicate_rows_ignored": duplicates,
            "missing_field_seconds": sum(raw is None for raw, _ in observed.values()),
            "recorded_zero_seconds": sum(raw == 0 for raw, _ in observed.values()),
            "out_of_band_nonzero_seconds": sum(raw is not None and raw != 0 and raw not in candidate.INBAND
                                               for raw, _ in observed.values()),
            "in_band_seconds": sum(raw in candidate.INBAND for raw, _ in observed.values()),
            "unknown_sleep_state_seconds": sum(state is None for _, state in observed.values()),
            "asleep_candidate_seconds": len(inband_candidates),
            "asleep_nonzero_candidate_seconds": len(comparison_candidates),
            "asleep_out_of_band_nonzero_seconds": len(asleep_out_of_band),
        },
        "comparison": None,
        "limitations": [
            "Byte @82 has no established physiological meaning or time-response model.",
            "Agreement with an independent device does not establish clinical accuracy.",
            "Repeated seconds and adjacent runs are not independent validation nights.",
            "Decoded backups cannot independently verify original frame CRCs or neighbouring offsets.",
            "No calibration, lag search, imputation or production SpO2 write is performed.",
        ],
    }
    if not observed:
        result["availability"] = "no_retained_records"
    elif not comparison_candidates:
        result["availability"] = "no_asleep_nonzero_candidate"
    else:
        # Capture-only inspection stays neutral; the explicit range-consistency fields
        # above expose falsifying evidence without pretending a reference was present.
        result["availability"] = "candidate_only"
    if reference is None:
        return result
    for ts, value in reference.items():
        if (type(ts) is not int or not 0 <= ts <= UINT32_MAX or isinstance(value, bool)
                or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 < value <= 100):
            raise ValueError("Invalid reference sample")
    paired = {
        ts: (float(raw), float(reference[ts]))
        for ts, raw in comparison_candidates.items() if ts in reference
    }
    fraction = len(paired) / len(comparison_candidates) if comparison_candidates else 0.0
    # Equal weighting of contiguous *observed* candidate runs avoids giving a dense
    # run more influence. This does not infer the strap's unknown duty-cycle schedule.
    runs: list[list[int]] = []
    for ts in sorted(comparison_candidates):
        if not runs or ts != runs[-1][-1] + 1:
            runs.append([])
        runs[-1].append(ts)
    run_pairs = []
    for run in runs:
        matches = [paired[ts] for ts in run if ts in paired]
        if len(matches) / len(run) >= MIN_MATCHED_FRACTION:
            run_pairs.append((statistics.fmean(pair[0] for pair in matches),
                              statistics.fmean(pair[1] for pair in matches)))
    coverage_complete = bool(paired) and fraction >= MIN_MATCHED_FRACTION
    sample_count_sufficient = len(paired) >= MIN_PAIRED_SECONDS
    metrics_allowed = coverage_complete and sample_count_sufficient
    result["comparison"] = {
        "valid_reference_seconds_in_window": sum(start <= ts < end for ts in reference),
        "paired_seconds": len(paired),
        "unpaired_candidate_seconds": len(comparison_candidates) - len(paired),
        "matched_candidate_fraction": fraction,
        "minimum_matched_fraction": MIN_MATCHED_FRACTION,
        "minimum_paired_seconds": MIN_PAIRED_SECONDS,
        "paired_sample_count_sufficient": sample_count_sufficient,
        "candidate_range_consistent": not asleep_out_of_band,
        "candidate_runs": len(runs),
        "sufficiently_paired_runs": len(run_pairs),
        "matched_sample_differences": metrics(list(paired.values())) if metrics_allowed else None,
        "equal_run_differences": metrics(run_pairs) if metrics_allowed else None,
    }
    if comparison_candidates:
        result["availability"] = (
            "candidate_range_violation" if asleep_out_of_band else
            "no_time_matched_pairs" if not paired else
            "insufficient_paired_samples" if not sample_count_sufficient else
            "paired_research_only" if coverage_complete else
            "insufficient_reference_overlap"
        )
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: Sequence[str] | None = None) -> int:
    configure_utf8_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backup", type=Path, help="Standalone NOOP app SQLite or .noopbak")
    parser.add_argument("--start", required=True, type=timestamp)
    parser.add_argument("--end", required=True, type=timestamp)
    parser.add_argument("--app-device", help="Select one stored device when multiple devices exist")
    parser.add_argument("--reference-csv", type=Path)
    parser.add_argument("--reference-metadata", type=Path)
    parser.add_argument("--output", type=Path, help="Create a new JSON report; existing files are never overwritten")
    args = parser.parse_args(argv)
    if bool(args.reference_csv) != bool(args.reference_metadata):
        parser.error("Provide both --reference-csv and --reference-metadata, or neither for capture-only inspection")
    try:
        inputs = {"capture": args.backup}
        if args.reference_csv:
            inputs.update(reference_csv=args.reference_csv, reference_metadata=args.reference_metadata)
        hashes = {name: sha256(path) for name, path in inputs.items()}
        with snapshot_path(args.backup) as snapshot:
            verified = open_verified_database(snapshot)
            verified.close()
            if not candidate.looks_like_app_db(str(snapshot)):
                raise ValueError("Expected a NOOP app database with v18AuxSample evidence")
            try:
                records = candidate.load_app_db_records(str(snapshot), device_id=args.app_device)
            except SystemExit as error:
                # The existing loader is also a CLI and reports selection/schema errors this way.
                raise ValueError(str(error)) from error
        metadata = read_metadata(args.reference_metadata) if args.reference_metadata else None
        reference, reference_counts = (read_reference(args.reference_csv,
                                      clock_offset_seconds=metadata["clock_offset_seconds"])
                                      if metadata else (None, None))
        result = analyze(records, args.start, args.end, reference)
        if any(sha256(path) != hashes[name] for name, path in inputs.items()):
            raise ValueError("An input changed during analysis; comparison refused")
        result["input_sha256"] = hashes
        result["reference_provenance"] = metadata
        result["reference_counts"] = reference_counts
        text = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
        if args.output:
            with args.output.open("x", encoding="utf-8", newline="\n") as output:
                output.write(text)
            print(f"Wrote {args.output}")
        else:
            print(text, end="")
        return 0
    except (ValueError, OSError) as error:
        print(f"SpO2 research comparison refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

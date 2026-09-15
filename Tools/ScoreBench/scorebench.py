#!/usr/bin/env python3
"""Blind, offline comparison of NOOP scalar predictions with WHOOP references.

Prediction generation is intentionally outside this program. ScoreBench only joins an already-written
prediction file to a separately-held reference file, preventing reference values from entering scorer input.
Standard-library only; no network, database writes, or production scorer changes.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any

SCHEMA_VERSION = 1
METRICS = (
    "recovery_score_pct",
    "sleep_performance_pct",
    "strain_0_21",
    "resting_heart_rate_bpm",
    "hrv_rmssd_ms",
    "respiratory_rate_rpm",
)
PHYSIOLOGICAL_RANGES = {
    "recovery_score_pct": (0.0, 100.0),
    "sleep_performance_pct": (0.0, 100.0),
    "strain_0_21": (0.0, 21.0),
    "resting_heart_rate_bpm": (25.0, 220.0),
    "hrv_rmssd_ms": (1.0, 500.0),
    "respiratory_rate_rpm": (4.0, 40.0),
}
PARTITIONS = ("development", "holdout")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ScoreBenchError(ValueError):
    pass


@dataclass(frozen=True)
class Row:
    sample_id: str
    participant_id: str | None
    partition: str | None
    values: dict[str, float | None]


def _load(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ScoreBenchError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ScoreBenchError(f"{path}: root must be an object")
    return value


def _finite_number(value: Any, where: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ScoreBenchError(f"{where}: expected a number or null")
    result = float(value)
    if not math.isfinite(result):
        raise ScoreBenchError(f"{where}: value must be finite")
    return result


def _rows(document: dict[str, Any], *, reference: bool) -> list[Row]:
    label = "reference" if reference else "prediction"
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ScoreBenchError(f"{label}: unsupported schema_version")
    raw_rows = document.get("rows")
    if not isinstance(raw_rows, list):
        raise ScoreBenchError(f"{label}: rows must be an array")
    seen: set[str] = set()
    participant_partitions: dict[str, str] = {}
    result: list[Row] = []
    for index, raw in enumerate(raw_rows):
        if not isinstance(raw, dict):
            raise ScoreBenchError(f"{label} row {index}: must be an object")
        sample_id = raw.get("sample_id")
        if not isinstance(sample_id, str) or not sample_id.strip():
            raise ScoreBenchError(f"{label} row {index}: invalid sample_id")
        if sample_id in seen:
            raise ScoreBenchError(f"{label}: duplicate sample_id {sample_id}")
        seen.add(sample_id)
        participant_id = raw.get("participant_id") if reference else None
        partition = raw.get("partition") if reference else None
        if reference:
            if not isinstance(participant_id, str) or not participant_id.strip():
                raise ScoreBenchError(f"reference row {index}: invalid participant_id")
            if partition not in PARTITIONS:
                raise ScoreBenchError(f"reference row {index}: invalid partition")
            prior = participant_partitions.setdefault(participant_id, partition)
            if prior != partition:
                raise ScoreBenchError(
                    f"reference: participant {participant_id} crosses development/holdout"
                )
        values = raw.get("values")
        if not isinstance(values, dict):
            raise ScoreBenchError(f"{label} row {index}: values must be an object")
        unknown = set(values) - set(METRICS)
        if unknown:
            raise ScoreBenchError(f"{label} row {index}: unknown metrics {sorted(unknown)}")
        parsed = {
            metric: _finite_number(values.get(metric), f"{label} {sample_id} {metric}")
            for metric in METRICS
        }
        if reference:
            for metric, value in parsed.items():
                if value is not None and not _in_range(metric, value):
                    raise ScoreBenchError(
                        f"reference {sample_id} {metric}: outside declared physiological range"
                    )
        result.append(Row(sample_id, participant_id, partition, parsed))
    return result


def _in_range(metric: str, value: float) -> bool:
    lower, upper = PHYSIOLOGICAL_RANGES[metric]
    return lower <= value <= upper


def _correlation(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 2:
        return None
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    dx, dy = [x - mx for x in xs], [y - my for y in ys]
    denominator = math.sqrt(sum(x * x for x in dx) * sum(y * y for y in dy))
    if denominator == 0:
        return None
    return sum(x * y for x, y in zip(dx, dy)) / denominator


def _metric_report(references: list[Row], predictions: dict[str, Row], metric: str) -> dict[str, Any]:
    observed = [row for row in references if row.values[metric] is not None]
    paired: list[tuple[float, float]] = []
    invalid = 0
    missing = 0
    for reference in observed:
        prediction = predictions.get(reference.sample_id)
        value = prediction.values[metric] if prediction else None
        if value is None:
            missing += 1
        elif not _in_range(metric, value):
            invalid += 1
        else:
            paired.append((value, reference.values[metric]))  # type: ignore[arg-type]
    errors = [prediction - reference for prediction, reference in paired]
    absolute = [abs(error) for error in errors]
    n_reference = len(observed)
    return {
        "n_reference": n_reference,
        "n_paired": len(paired),
        "n_missing_prediction": missing,
        "n_invalid_prediction": invalid,
        "coverage": len(paired) / n_reference if n_reference else None,
        "mae": sum(absolute) / len(absolute) if absolute else None,
        "rmse": math.sqrt(sum(error * error for error in errors) / len(errors)) if errors else None,
        "bias": sum(errors) / len(errors) if errors else None,
        "pearson_r": _correlation([pair[0] for pair in paired], [pair[1] for pair in paired]),
        "physiological_range": list(PHYSIOLOGICAL_RANGES[metric]),
    }


def evaluate(prediction_document: dict[str, Any], reference_document: dict[str, Any]) -> dict[str, Any]:
    predictions = _rows(prediction_document, reference=False)
    references = _rows(reference_document, reference=True)
    split_sha = reference_document.get("split_plan_sha256")
    if not isinstance(split_sha, str) or not SHA256_RE.fullmatch(split_sha):
        raise ScoreBenchError("reference: split_plan_sha256 must be a lowercase SHA-256")
    model_id = prediction_document.get("model_id")
    dataset_id = reference_document.get("dataset_id")
    if not isinstance(model_id, str) or not model_id.strip():
        raise ScoreBenchError("prediction: model_id is required")
    if not isinstance(dataset_id, str) or not dataset_id.strip():
        raise ScoreBenchError("reference: dataset_id is required")
    by_id = {row.sample_id: row for row in predictions}
    partitions: dict[str, Any] = {}
    for partition in PARTITIONS:
        selected = [row for row in references if row.partition == partition]
        partitions[partition] = {
            metric: _metric_report(selected, by_id, metric) for metric in METRICS
        }
    return {
        "schema_version": SCHEMA_VERSION,
        "model_id": model_id,
        "dataset_id": dataset_id,
        "split_plan_sha256": split_sha,
        "metrics": list(METRICS),
        "partitions": partitions,
    }


def promotion_gate(incumbent: dict[str, Any], candidate: dict[str, Any], metrics: list[str]) -> dict[str, Any]:
    for field in ("dataset_id", "split_plan_sha256"):
        if incumbent.get(field) != candidate.get(field):
            raise ScoreBenchError(f"reports use different {field}")
    unknown = set(metrics) - set(METRICS)
    if unknown:
        raise ScoreBenchError(f"unknown gate metrics {sorted(unknown)}")
    decisions: dict[str, Any] = {}
    improved = False
    all_pass = True
    for metric in metrics:
        old = incumbent["partitions"]["holdout"][metric]
        new = candidate["partitions"]["holdout"][metric]
        same_reference = old["n_reference"] == new["n_reference"] and old["n_reference"] > 0
        safeguards = new["n_invalid_prediction"] == 0
        coverage_ok = new["coverage"] is not None and old["coverage"] is not None \
            and new["coverage"] >= old["coverage"]
        mae_ok = new["mae"] is not None and old["mae"] is not None and new["mae"] <= old["mae"]
        rmse_ok = new["rmse"] is not None and old["rmse"] is not None and new["rmse"] <= old["rmse"]
        metric_improved = mae_ok and new["mae"] < old["mae"]
        passed = same_reference and safeguards and coverage_ok and mae_ok and rmse_ok
        improved = improved or (passed and metric_improved)
        all_pass = all_pass and passed
        decisions[metric] = {
            "pass": passed,
            "strict_mae_improvement": metric_improved,
            "same_reference": same_reference,
            "physiological_safeguards": safeguards,
            "coverage_not_reduced": coverage_ok,
            "mae_not_worse": mae_ok,
            "rmse_not_worse": rmse_ok,
        }
    promote = all_pass and improved
    return {
        "promote": promote,
        "rule": "all selected holdout metrics preserve coverage/safeguards/MAE/RMSE; at least one lowers MAE",
        "metrics": decisions,
    }


def _write_json(value: dict[str, Any], output: pathlib.Path | None) -> None:
    text = json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n"
    if output:
        output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    evaluate_parser = subcommands.add_parser("evaluate")
    evaluate_parser.add_argument("--predictions", type=pathlib.Path, required=True)
    evaluate_parser.add_argument("--references", type=pathlib.Path, required=True)
    evaluate_parser.add_argument("--output", type=pathlib.Path)
    gate_parser = subcommands.add_parser("gate")
    gate_parser.add_argument("--incumbent", type=pathlib.Path, required=True)
    gate_parser.add_argument("--candidate", type=pathlib.Path, required=True)
    gate_parser.add_argument("--metric", action="append", choices=METRICS)
    gate_parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "evaluate":
            result = evaluate(_load(args.predictions), _load(args.references))
        else:
            result = promotion_gate(_load(args.incumbent), _load(args.candidate), args.metric or list(METRICS))
        _write_json(result, args.output)
        return 0 if args.command == "evaluate" or result["promote"] else 2
    except (ScoreBenchError, KeyError, TypeError) as error:
        print(f"scorebench: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

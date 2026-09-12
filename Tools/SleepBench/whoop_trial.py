#!/usr/bin/env python3
"""Read-only stored-session comparison. No staging, fitting, or health-data upload.

English WHOOP sleeps.csv adapter follows WhoopExportImporter field names. It is
deliberately separate from Swift replay: SleepBench's current stream reads differ
from the app. Missing channels/metrics are null, never physiological zero.
"""
import argparse
import csv
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import math
from pathlib import Path
import re
import sqlite3
import statistics
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backup_validation import open_verified_database, snapshot_path

BASELINE = "ad05ec686103e483eea3627d8ab0e4a7e65cf2f5"
FIELDS = {
    "asleep_min": "asleep_duration_min", "in_bed_min": "in_bed_duration_min",
    "light_min": "light_sleep_duration_min", "deep_min": "deep_sws_duration_min",
    "rem_min": "rem_duration_min", "awake_min": "awake_duration_min",
    "efficiency_pct": "sleep_efficiency_pct",
}


def key(value):
    return re.sub(r"[^a-z0-9]+", "_", value.lower().replace("%", "pct")).strip("_")


def number(value):
    if value is None or str(value).strip() == "":
        return None
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError("Invalid nonnegative metric")
    return result


def timestamp(value, offset):
    dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    if dt.tzinfo is None:
        match = re.fullmatch(r"(?:UTC|GMT)?\s*([+-])(\d{2}):?(\d{2})", offset.strip())
        if not match:
            raise ValueError("Naive timestamp requires explicit Cycle timezone offset")
        sign, hours, minutes = match.groups()
        if int(minutes) >= 60 or int(hours) > 23:
            raise ValueError("Invalid timezone offset")
        delta = (int(hours) * 60 + int(minutes)) * (1 if sign == "+" else -1)
        dt = dt.replace(tzinfo=timezone(timedelta(minutes=delta)))
    return int(dt.timestamp())


def read_whoop(path):
    """Read one sleeps.csv, including nested ZIP/folder, without extracting ZIPs."""
    path = Path(path)
    limit = 20_000_000
    if path.is_dir():
        found = [p for p in path.rglob("*") if p.name.lower() == "sleeps.csv"]
        if len(found) != 1:
            raise ValueError("Expected exactly one sleeps.csv")
        return read_whoop(found[0])
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            found = [x for x in archive.infolist() if Path(x.filename).name.lower() == "sleeps.csv"]
            if len(found) != 1 or found[0].file_size > limit:
                raise ValueError("Expected one sleeps.csv under 20 MB")
            data = archive.read(found[0])
    else:
        if path.stat().st_size > limit:
            raise ValueError("CSV exceeds 20 MB")
        data = path.read_bytes()
    reader = csv.DictReader(io.StringIO(data.decode("utf-8-sig")))
    headers = [key(h) for h in (reader.fieldnames or [])]
    if len(set(headers)) != len(headers) or not {"sleep_onset", "wake_onset"} <= set(headers):
        raise ValueError("Unsupported/duplicate CSV headers; English WHOOP sleep headers required")
    result, seen = [], set()
    for index, raw in enumerate(reader, 2):
        if None in raw:
            raise ValueError(f"Malformed CSV row {index}")
        row = {key(k): v for k, v in raw.items()}
        nap = (row.get("nap") or "false").strip().lower()
        if nap not in ("true", "false", "1", "0", "yes", "no"):
            raise ValueError(f"Invalid nap flag on row {index}")
        start = timestamp(row["sleep_onset"], row.get("cycle_timezone") or "")
        end = timestamp(row["wake_onset"], row.get("cycle_timezone") or "")
        if end <= start:
            raise ValueError(f"Nonpositive interval on row {index}")
        metrics = {k: number(row.get(v)) for k, v in FIELDS.items()}
        if metrics["deep_min"] is None:
            metrics["deep_min"] = number(row.get("deep_sleep_duration_min"))
        signature = (start, end)
        if signature in seen:
            raise ValueError("Duplicate WHOOP interval; resolve export revisions explicitly")
        seen.add(signature)
        result.append(dict(start=start, end=end, nap=nap in ("true", "1", "yes"), metrics=metrics))
    return result, hashlib.sha256(data).hexdigest()


def open_snapshot(path):
    db = open_verified_database(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    return db


def columns(db, table):
    # Table identifiers below are internal constants, never CLI input.
    return {r[1] for r in db.execute(f'PRAGMA table_info("{table}")')}


def sessions(db, device):
    required = {"deviceId", "startTs", "endTs", "stagesJSON", "userEdited"}
    cols = columns(db, "sleepSession")
    if not required <= cols:
        raise ValueError("Unsupported sleepSession schema")
    result = []
    for row in db.execute("SELECT * FROM sleepSession WHERE deviceId=? ORDER BY startTs", (device,)):
        start = row["startTsAdjusted"] if "startTsAdjusted" in cols and row["startTsAdjusted"] is not None else row["startTs"]
        end = row["endTs"]
        if end <= start:
            raise ValueError("Nonpositive NOOP session")
        metrics = dict.fromkeys(FIELDS)
        metrics["in_bed_min"] = (end - start) / 60
        issue = None
        try:
            segments = json.loads(row["stagesJSON"] or "null")
            if not isinstance(segments, list) or not segments:
                raise ValueError("No timed hypnogram")
            totals = dict.fromkeys(("wake", "light", "deep", "rem"), 0.0)
            cursor = start
            for seg in sorted(segments, key=lambda s: s["start"]):
                lo, hi = max(start, seg["start"]), min(end, seg["end"])
                if hi <= lo:
                    continue
                if lo != cursor or seg["stage"] not in totals:
                    raise ValueError("Gapped/overlapping/unknown hypnogram")
                totals[seg["stage"]] += (hi - lo) / 60
                cursor = hi
            if cursor != end:
                raise ValueError("Incomplete hypnogram")
            for stage in ("light", "deep", "rem"):
                metrics[stage + "_min"] = totals[stage]
            metrics["awake_min"] = totals["wake"]
            metrics["asleep_min"] = sum(totals[s] for s in ("light", "deep", "rem"))
            metrics["efficiency_pct"] = 100 * metrics["asleep_min"] / metrics["in_bed_min"]
        except (ValueError, TypeError, KeyError) as exc:
            issue = str(exc)
        result.append(dict(start=start, end=end, stored_start=row["startTs"],
                           edited=bool(row["userEdited"]), metrics=metrics, issue=issue))
    return result


def coverage(db, device, start, end):
    """Unique occupied seconds / window seconds, NOT feature validity or accuracy.

    RR reports raw presence only: app source selection depends on its broader
    read window and resolved device identity. No false app-equivalence claim.
    """
    sets = {}
    for name, table in (("hr_measured", "hrSample"), ("hr_ppg_derived", "ppgHrSample"),
                        ("rr_raw", "rrInterval"), ("gravity", "gravitySample"),
                        ("resp_raw", "respSample"), ("band_state", "sleepStateSample")):
        cols = columns(db, table)
        if not cols:
            sets[name] = None
            continue
        if not {"deviceId", "ts"} <= cols:
            raise ValueError(f"Unsupported {table} schema")
        sets[name] = {r[0] for r in db.execute(
            f'SELECT DISTINCT ts FROM "{table}" WHERE deviceId=? AND ts>=? AND ts<?',
            (device, start, end))}
    measured, derived = sets["hr_measured"], sets["hr_ppg_derived"]
    sets["hr_union"] = None if measured is None or derived is None else measured | derived
    sets["hr_ppg_only"] = None if measured is None or derived is None else derived - measured
    gravity = sets["gravity"]
    # Valid time-adjacent pairs; one sample cannot prove stillness.
    sets["motion_adjacent_pairs"] = None if gravity is None else {t for t in gravity if t - 1 in gravity}
    result = {k + "_coverage": None if v is None else len(v) / (end - start) for k, v in sets.items()}
    rrcols = columns(db, "rrInterval")
    result["rr_rows_by_source"] = None
    if {"srcChannel", "deviceId", "ts"} <= rrcols:
        result["rr_rows_by_source"] = {str(r[0]): r[1] for r in db.execute(
            "SELECT srcChannel,COUNT(*) FROM rrInterval WHERE deviceId=? AND ts>=? AND ts<? GROUP BY srcChannel",
            (device, start, end))}
    return result


def pair(noop, whoop, min_overlap=0.5):
    """Only unambiguous mutual one-to-one overlap matches; never date-only matching."""
    candidates = []
    for n in noop:
        candidates.append([j for j, w in enumerate(whoop)
                           if max(0, min(n["end"], w["end"]) - max(n["start"], w["start"]))
                           / max(n["end"] - n["start"], w["end"] - w["start"]) >= min_overlap])
    counts = [sum(j in c for c in candidates) for j in range(len(whoop))]
    pairs = [(i, c[0]) for i, c in enumerate(candidates) if len(c) == 1 and counts[c[0]] == 1]
    return pairs, [i for i, c in enumerate(candidates) if c and not any(i == p[0] for p in pairs)]


def stats(pairs):
    if not pairs:
        return dict(n=0, mae=None, bias=None, median_error=None, correlation=None)
    x, y = zip(*pairs)
    errors = [a - b for a, b in pairs]
    corr = None
    if len(pairs) >= 3 and len(set(x)) > 1 and len(set(y)) > 1:
        mx, my = statistics.mean(x), statistics.mean(y)
        corr = sum((a - mx) * (b - my) for a, b in pairs) / math.sqrt(
            sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))
    return dict(n=len(pairs), mae=statistics.mean(map(abs, errors)), bias=statistics.mean(errors),
                median_error=statistics.median(errors), correlation=corr)


def compare(db, device, stream_device, whoop):
    ns = sessions(db, device)
    ws = [w for w in whoop if not w["nap"]]
    matches, ambiguous = pair(ns, ws)
    rows = []
    for i, j in matches:
        n, w = ns[i], ws[j]
        row = dict(noop_start=n["start"], whoop_start=w["start"], noop_end=n["end"], whoop_end=w["end"],
                   onset_error_min=(n["start"] - w["start"]) / 60,
                   wake_error_min=(n["end"] - w["end"]) / 60,
                   edited=n["edited"], hypnogram_issue=n["issue"])
        for metric in FIELDS:
            a, b = n["metrics"][metric], w["metrics"][metric]
            row["noop_" + metric], row["whoop_" + metric] = a, b
            row[metric + "_error"] = None if a is None or b is None else a - b
        # Sleep-stage shares use TST; awake uses time in bed. Denominators are explicit.
        for stage in ("light", "deep", "rem", "awake"):
            denom = "in_bed_min" if stage == "awake" else "asleep_min"
            shares = []
            for side, obj in (("noop", n), ("whoop", w)):
                value, total = obj["metrics"][stage + "_min"], obj["metrics"][denom]
                share = None if value is None or total is None or total <= 0 else 100 * value / total
                row[f"{side}_{stage}_share_pct"] = share
                shares.append(share)
            row[stage + "_share_error_pp"] = None if None in shares else shares[0] - shares[1]
        # Coverage on BOTH windows avoids hiding missing data outside NOOP's detected span.
        for label, obj in (("noop", n), ("whoop", w)):
            row.update({label + "_" + k: v for k, v in coverage(db, stream_device, obj["start"], obj["end"]).items()})
        motion = row["whoop_motion_adjacent_pairs_coverage"]
        row["motion_stratum"] = "unknown" if motion is None else "high" if motion >= .8 else "medium" if motion >= .4 else "low"
        rows.append(row)
    def aggregate(subset):
        out = {}
        for metric in list(FIELDS) + [s + "_share_pct" for s in ("light", "deep", "rem", "awake")]:
            out[metric] = stats([(r["noop_" + metric], r["whoop_" + metric]) for r in subset
                                 if r["noop_" + metric] is not None and r["whoop_" + metric] is not None])
        for metric in ("onset_error_min", "wake_error_min"):
            out[metric] = stats([(r[metric], 0) for r in subset])
        return out
    # Human-edited stored sessions are visible, but excluded from machine agreement summaries.
    machine = [r for r in rows if not r["edited"]]
    return dict(mode="stored_results_only", source_baseline=BASELINE, nights=rows,
                matched=len(rows), noop_unmatched=len(ns) - len(matches), whoop_unmatched=len(ws) - len(matches),
                ambiguous_noop_sessions=[ns[i]["start"] for i in ambiguous],
                excluded_whoop_naps=sum(w["nap"] for w in whoop),
                summary=aggregate(machine),
                by_motion={s: aggregate([r for r in machine if r["motion_stratum"] == s])
                           for s in ("high", "medium", "low", "unknown")})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="Standalone copy, never live database")
    parser.add_argument("--whoop", required=True, help="Export ZIP, folder, or sleeps.csv")
    parser.add_argument("--device", required=True, help="Computed sleep-session owner")
    parser.add_argument("--stream-device", required=True, help="Raw sensor owner")
    parser.add_argument("--out", required=True, help="New private output JSON path")
    args = parser.parse_args()
    ws, csv_hash = read_whoop(args.whoop)
    with snapshot_path(args.db) as path:
        db = open_snapshot(path)
        try:
            report = compare(db, args.device, args.stream_device, ws)
        finally:
            db.close()
    report["whoop_csv_sha256"] = csv_hash
    report["limitations"] = [
        "Agreement with WHOOP is not PSG accuracy; no epoch reference is supplied.",
        "Stored session bounds are not independently verified physiological sleep onset.",
        "Coverage is occupied seconds, not usable-feature quality; RR is raw, not app-filtered.",
        "Ambiguous/fragmented matches are withheld; no automatic session merging.",
        "No Swift replay, algorithm fitting, or probabilities are performed.",
    ]
    with open(args.out, "x", encoding="utf-8") as output:
        json.dump(report, output, indent=2, allow_nan=False)
        output.write("\n")
    print(f"Compared {report['matched']} nights; stored results only.")


if __name__ == "__main__":
    main()

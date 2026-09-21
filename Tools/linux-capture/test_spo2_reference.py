"""Synthetic evidence only: time matching, no-overlap, integrity and CLI regressions."""
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
import zipfile

import spo2_reference as research

START = 1780000000


def row(ts, value, state=2):
    return {"unix": ts, "aux_byte_82": value, "sleep_state": state}


def metadata():
    return {"reference_kind": "independent_oximeter", "reference_device": "synthetic-fixture",
            "reference_firmware": "fixture-1", "capture_device_model": "WHOOP 5.0",
            "capture_firmware": "fixture-1", "same_wearer": True,
            "clock_offset_seconds": 0, "clock_alignment_note": "Synthetic aligned clocks",
            "partition": "development"}


def write_database(path, records, device="test-strap", append=False):
    db = sqlite3.connect(path)
    try:
        if not append:
            db.executescript("""
                CREATE TABLE v18AuxSample(deviceId TEXT, ts INTEGER, fields BLOB,
                                         PRIMARY KEY(deviceId, ts));
                CREATE TABLE sleepStateSample(deviceId TEXT, ts INTEGER, state INTEGER,
                                              PRIMARY KEY(deviceId, ts));
            """)
        for record in records:
            value = record["aux_byte_82"]
            blob = struct.pack("<BI", 2, 1 << 11 if value is not None else 0)
            if value is not None:
                blob += bytes([value])
            db.execute("INSERT INTO v18AuxSample VALUES (?,?,?)", (device, record["unix"], blob))
            if record["sleep_state"] is not None:
                db.execute("INSERT INTO sleepStateSample VALUES (?,?,?)",
                           (device, record["unix"], record["sleep_state"]))
        db.commit()
    finally:
        db.close()


class EvidenceTests(unittest.TestCase):
    def test_missing_zero_status_and_unknown_sleep_are_distinct(self):
        result = research.analyze([row(START, None), row(START+1, 0), row(START+2, 160),
                                   row(START+3, 97, None), row(START+4, 96)], START, START+10)
        counts = result["observations"]
        self.assertEqual(counts["missing_field_seconds"], 1)
        self.assertEqual(counts["recorded_zero_seconds"], 1)
        self.assertEqual(counts["out_of_band_nonzero_seconds"], 1)
        self.assertEqual(counts["unknown_sleep_state_seconds"], 1)
        self.assertEqual(counts["in_band_seconds"], 2)
        self.assertEqual(counts["asleep_candidate_seconds"], 1)
        self.assertEqual(counts["retained_fraction"], 0.5)
        self.assertEqual(counts["largest_missing_gap_seconds"], 5)
        self.assertEqual(result["availability"], "candidate_only")
        self.assertIsNone(result["comparison"])
        self.assertFalse(result["promotion_allowed"])

    def test_no_records_is_not_zero_oxygen(self):
        result = research.analyze([], START, START+100, {START: 97})
        self.assertEqual(result["availability"], "no_retained_records")
        self.assertEqual(result["observations"]["largest_missing_gap_seconds"], 100)
        self.assertIsNone(result["comparison"]["matched_sample_differences"])

    def test_wrong_night_and_adjacent_seconds_are_never_paired(self):
        for timestamp in (START-1, START+1, START+86400):
            with self.subTest(timestamp=timestamp):
                result = research.analyze([row(START, 97)], START, START+2, {timestamp: 97})
                self.assertEqual(result["availability"], "no_time_matched_pairs")
                self.assertIsNone(result["comparison"]["matched_sample_differences"])

    def test_boundary_is_half_open_and_gaps_are_not_filled(self):
        records = [row(START-1, 97), row(START, 97), row(START+9, 97), row(START+10, 97)]
        result = research.analyze(records, START, START+10)
        self.assertEqual(result["observations"]["retained_seconds"], 2)
        self.assertEqual(result["observations"]["largest_missing_gap_seconds"], 8)

    def test_duplicate_samples_are_idempotent_conflicts_are_refused(self):
        one = research.analyze([row(START, 97)], START, START+1, {START: 96})
        repeated = research.analyze([row(START, 97)]*100, START, START+1, {START: 96})
        self.assertEqual(one["comparison"], repeated["comparison"])
        self.assertEqual(repeated["observations"]["retained_seconds"], 1)
        with self.assertRaisesRegex(ValueError, "Conflicting NOOP"):
            research.analyze([row(START, 97), row(START, 95)], START, START+1)

    def test_sparse_reference_cannot_emit_accuracy_like_statistics(self):
        records = [row(START+i, 97) for i in range(10)]
        result = research.analyze(records, START, START+10, {START: 97})
        self.assertEqual(result["availability"], "insufficient_reference_overlap")
        self.assertEqual(result["comparison"]["paired_seconds"], 1)
        self.assertIsNone(result["comparison"]["matched_sample_differences"])

    def test_varying_inputs_and_opposite_errors_have_expected_metrics(self):
        result = research.analyze([row(START, 94), row(START+1, 98)], START, START+2,
                                  {START: 96, START+1: 96})
        values = result["comparison"]["matched_sample_differences"]
        self.assertEqual(values["candidate_minus_reference_mean"], 0)
        self.assertEqual(values["mean_absolute_difference"], 2)
        self.assertEqual(values["root_mean_squared_difference"], 2)
        self.assertIsNone(values["pearson_r"])
        self.assertEqual(result["availability"], "paired_research_only")
        self.assertFalse(result["promotion_allowed"])

    def test_perfect_correlation_does_not_promote(self):
        records = [row(START+i, value) for i, value in enumerate((92, 95, 99))]
        result = research.analyze(records, START, START+3,
                                  {record["unix"]: record["aux_byte_82"] for record in records})
        self.assertAlmostEqual(result["comparison"]["matched_sample_differences"]["pearson_r"], 1)
        self.assertEqual(result["evidence_status"], "experimental_unvalidated")
        self.assertFalse(result["promotion_allowed"])

    def test_equal_runs_do_not_overweight_dense_candidate_bursts(self):
        records = [row(START+i, 99) for i in range(10)] + [row(START+20, 95)]
        result = research.analyze(records, START, START+21, {r["unix"]: 97 for r in records})
        comparison = result["comparison"]
        self.assertEqual(comparison["candidate_runs"], 2)
        self.assertEqual(comparison["equal_run_differences"]["candidate_minus_reference_mean"], 0)
        self.assertAlmostEqual(comparison["matched_sample_differences"]["candidate_minus_reference_mean"], 18/11)

    def test_invalid_windows_and_nonfinite_references_are_refused(self):
        for start, end in ((START, START), (START+1, START), (-1, START), (0, 2**32)):
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                research.analyze([], start, end)
        for value in (float("nan"), float("inf"), 101, 0, -1, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                research.analyze([row(START, 97)], START, START+1, {START: value})


class TemporaryFiles(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)


class ReferenceInputTests(TemporaryFiles):
    def reference(self, rows, offset=0):
        path = self.root / "reference.csv"
        path.write_text("timestamp,spo2_percent,quality\n" + rows, encoding="utf-8")
        return research.read_reference(path, clock_offset_seconds=offset)

    def test_explicit_timezone_is_preserved(self):
        self.assertEqual(research.timestamp("2026-09-20T22:00:00+01:00"),
                         research.timestamp("2026-09-20T21:00:00Z"))
        for value in ("2026-09-20T22:00:00", "2026-09-20", "2026-09-20T22:00:00.5Z", "NaN"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                research.timestamp(value)

    def test_measured_clock_offset_and_explicit_quality(self):
        samples, counts = self.reference(f"{START},97,valid\n{START+1},,invalid\n", offset=2)
        self.assertEqual(samples, {START+2: 97})
        self.assertEqual(counts["invalid_quality"], 1)

    def test_duplicate_reference_rows_do_not_weight_result(self):
        samples, counts = self.reference(f"{START},97,valid\n"*5)
        self.assertEqual(samples, {START: 97})
        self.assertEqual(counts["duplicates"], 4)

    def test_reference_conflict_or_conflicting_quality_is_refused(self):
        for second in ("96,valid", "97,invalid"):
            with self.subTest(second=second), self.assertRaisesRegex(ValueError, "Conflicting reference"):
                self.reference(f"{START},97,valid\n{START},{second}\n")

    def test_invalid_value_or_unknown_quality_is_not_silently_dropped(self):
        for sample in ("nan,valid", "inf,valid", "101,valid", "0,valid", "97,unknown", "97,valid,extra"):
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                self.reference(f"{START},{sample}\n")

    def test_low_reference_value_is_retained_to_expose_disagreement(self):
        samples, _ = self.reference(f"{START},65,valid\n")
        result = research.analyze([row(START, 97)], START, START+1, samples)
        self.assertEqual(result["comparison"]["matched_sample_differences"]["mean_absolute_difference"], 32)

    def test_missing_or_nonindependent_provenance_is_refused(self):
        path = self.root / "metadata.json"
        for key, value in (("reference_kind", "whoop_export"), ("same_wearer", False),
                           ("clock_offset_seconds", 0.5), ("clock_offset_seconds", True),
                           ("clock_alignment_note", ""), ("partition", "tuned")):
            data = metadata()
            data[key] = value
            path.write_text(json.dumps(data), encoding="utf-8")
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                research.read_metadata(path)


class CommandLineTests(TemporaryFiles):
    def invoke(self, backup, extra=()):
        stdout, stderr = io.StringIO(), io.StringIO()
        args = [str(backup), "--start", str(START), "--end", str(START+10), *map(str, extra)]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = research.main(args)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_real_sqlite_and_archive_pipeline_is_read_only_and_missing_data_stays_missing(self):
        database = self.root / "noop # percent%.sqlite"
        write_database(database, [row(START, 97), row(START+1, None), row(START+2, 0)])
        archive = self.root / "input.noopbak"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.write(database, "noop-backup.sqlite")
        for source in (database, archive):
            before = research.sha256(source)
            code, stdout, stderr = self.invoke(source)
            self.assertEqual(code, 0, stderr)
            result = json.loads(stdout)
            self.assertEqual(result["observations"]["asleep_candidate_seconds"], 1)
            self.assertEqual(result["observations"]["missing_field_seconds"], 1)
            self.assertEqual(result["observations"]["recorded_zero_seconds"], 1)
            self.assertEqual(result["input_sha256"]["capture"], before)
            self.assertEqual(research.sha256(source), before)

    def test_independent_csv_provenance_and_holdout_label_reach_report(self):
        database = self.root / "noop.sqlite"
        write_database(database, [row(START, 95), row(START+1, 97), row(START+2, 99)])
        reference = self.root / "ref.csv"
        reference.write_text(f"timestamp,spo2_percent,quality\n{START},95,valid\n"
                             f"{START+1},97,valid\n{START+2},99,valid\n", encoding="utf-8")
        meta = metadata()
        meta["partition"] = "holdout"
        sidecar = self.root / "ref.json"
        sidecar.write_text(json.dumps(meta), encoding="utf-8")
        code, stdout, stderr = self.invoke(database, ["--reference-csv", reference,
                                                    "--reference-metadata", sidecar])
        self.assertEqual(code, 0, stderr)
        result = json.loads(stdout)
        self.assertEqual(result["reference_provenance"]["partition"], "holdout")
        self.assertEqual(result["comparison"]["paired_seconds"], 3)
        self.assertEqual(set(result["input_sha256"]), {"capture", "reference_csv", "reference_metadata"})
        self.assertFalse(result["promotion_allowed"])

    def test_multiple_straps_require_explicit_selection(self):
        database = self.root / "noop.sqlite"
        write_database(database, [row(START, 95)], device="one")
        write_database(database, [row(START, 99)], device="two", append=True)
        code, _, error = self.invoke(database)
        self.assertEqual(code, 2)
        self.assertIn("--app-device", error)
        code, stdout, error = self.invoke(database, ["--app-device", "one"])
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(stdout)["observations"]["retained_seconds"], 1)

    def test_live_store_and_existing_output_are_refused(self):
        database = self.root / "noop.sqlite"
        write_database(database, [row(START, 97)])
        sidecar = Path(str(database) + "-wal")
        sidecar.write_bytes(b"")
        code, _, error = self.invoke(database)
        self.assertEqual(code, 2)
        self.assertIn("standalone", error)
        sidecar.unlink()
        output = self.root / "report.json"
        output.write_text("original", encoding="utf-8")
        code, _, _ = self.invoke(database, ["--output", output])
        self.assertEqual(code, 2)
        self.assertEqual(output.read_text(encoding="utf-8"), "original")


if __name__ == "__main__":
    unittest.main()

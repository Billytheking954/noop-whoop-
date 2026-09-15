import importlib.util
import pathlib
import sys
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("scorebench.py")
SPEC = importlib.util.spec_from_file_location("scorebench", MODULE_PATH)
S = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = S
SPEC.loader.exec_module(S)


def values(offset=0.0):
    return {
        "recovery_score_pct": 70 + offset,
        "sleep_performance_pct": 85 + offset,
        "strain_0_21": 5 + offset,
        "resting_heart_rate_bpm": 55 + offset,
        "hrv_rmssd_ms": 60 + offset,
        "respiratory_rate_rpm": 14 + offset,
    }


class ScoreBenchTests(unittest.TestCase):
    def references(self):
        return {
            "schema_version": 1,
            "dataset_id": "sealed-fixture-v1",
            "split_plan_sha256": "a" * 64,
            "rows": [
                {"sample_id": "d1", "participant_id": "p1", "partition": "development", "values": values()},
                {"sample_id": "h1", "participant_id": "p2", "partition": "holdout", "values": values()},
                {"sample_id": "h2", "participant_id": "p2", "partition": "holdout", "values": values(10)},
            ],
        }

    def predictions(self, error=2.0):
        return {
            "schema_version": 1,
            "model_id": "noop-test",
            "rows": [
                {"sample_id": "d1", "values": values(error)},
                {"sample_id": "h1", "values": values(error)},
                {"sample_id": "h2", "values": values(10 + error)},
            ],
        }

    def test_reports_all_six_metrics_on_separate_holdout(self):
        report = S.evaluate(self.predictions(), self.references())
        self.assertEqual(set(report["metrics"]), set(S.METRICS))
        for metric in S.METRICS:
            row = report["partitions"]["holdout"][metric]
            self.assertEqual(row["n_reference"], 2)
            self.assertEqual(row["n_paired"], 2)
            self.assertEqual(row["coverage"], 1.0)
            self.assertAlmostEqual(row["mae"], 2.0)
            self.assertAlmostEqual(row["bias"], 2.0)

    def test_missing_and_out_of_range_predictions_reduce_coverage_and_are_visible(self):
        prediction = self.predictions()
        prediction["rows"][1]["values"]["recovery_score_pct"] = 120
        prediction["rows"][2]["values"]["recovery_score_pct"] = None
        row = S.evaluate(prediction, self.references())["partitions"]["holdout"]["recovery_score_pct"]
        self.assertEqual(row["n_invalid_prediction"], 1)
        self.assertEqual(row["n_missing_prediction"], 1)
        self.assertEqual(row["coverage"], 0.0)

    def test_participant_cannot_cross_split(self):
        reference = self.references()
        reference["rows"][1]["participant_id"] = "p1"
        with self.assertRaisesRegex(S.ScoreBenchError, "crosses development/holdout"):
            S.evaluate(self.predictions(), reference)

    def test_reference_outside_physiological_range_is_rejected(self):
        reference = self.references()
        reference["rows"][0]["values"]["strain_0_21"] = 99
        with self.assertRaisesRegex(S.ScoreBenchError, "outside declared physiological range"):
            S.evaluate(self.predictions(), reference)

    def test_promotion_requires_strict_holdout_gain_without_coverage_or_rmse_regression(self):
        incumbent = S.evaluate(self.predictions(error=2), self.references())
        candidate = S.evaluate(self.predictions(error=1), self.references())
        gate = S.promotion_gate(incumbent, candidate, list(S.METRICS))
        self.assertTrue(gate["promote"])

        candidate["partitions"]["holdout"]["hrv_rmssd_ms"]["coverage"] = 0.5
        self.assertFalse(S.promotion_gate(incumbent, candidate, list(S.METRICS))["promote"])


if __name__ == "__main__":
    unittest.main()

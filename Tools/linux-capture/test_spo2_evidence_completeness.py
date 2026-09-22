"""Regression: honest N/A evidence must never become a fully-passing research summary."""
from copy import deepcopy
import tempfile
import unittest

import validate_spo2_candidate as vs
from test_validate_spo2_candidate import _write_app_db, _write_export, _utc


class EvidenceCompletenessTests(unittest.TestCase):
    def test_app_database_correlation_stays_incomplete_without_specificity_scan(self):
        with tempfile.TemporaryDirectory() as td:
            base = _utc(2026, 4, 1)
            rows = []
            exports = []
            for night, value in enumerate((94, 95, 96, 97, 98, 99)):
                start = base + night * 86400
                rows.extend((start + second, value, 2) for second in range(30))
                exports.append((f"2026-04-{night + 1:02d} 00:00:00", value, start, start + 30))

            db = _write_app_db(td, rows)
            export = _write_export(td, exports)
            result = vs.validate_device(db, export, device="app-db")

        self.assertEqual(result["specificity_scan"], "unavailable_app_db")
        self.assertIsNone(result["checklist"]["offset_82_wins"])
        self.assertTrue(result["checklist"]["pass"], "measured checks should still report honestly")
        self.assertFalse(result["checklist"]["evidence_complete"])
        self.assertEqual(result["classification"], "incomplete")

        second = deepcopy(result)
        second["device"] = "app-db-2"
        postable = vs.format_postable([result, second])
        self.assertIn("all_pass=False", postable)
        self.assertIn("instrumentation-only", postable)
        self.assertNotIn("promote spo2Pct", postable)


if __name__ == "__main__":
    unittest.main()

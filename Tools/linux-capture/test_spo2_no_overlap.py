"""Synthetic regressions for absent overlap and unsupported checklist results."""
import sqlite3
import tempfile
import unittest

import validate_spo2_candidate as vs
from test_validate_spo2_candidate import _write_app_db, _write_export, _utc


class NoOverlapTests(unittest.TestCase):
    def test_other_night_values_are_not_a_failed_measurement(self):
        with tempfile.TemporaryDirectory() as td:
            start = _utc(2025, 1, 1)
            db = _write_app_db(td, [(start+i, 95+i % 6, 2) for i in range(60)])
            export = _write_export(td, [('2025-01-02 00:00:00', 97, start+86400, start+90000)])
            res = vs.validate_device(db, export)
        self.assertEqual(res['classification'], 'no_overlap')
        self.assertFalse(res['checklist']['pass'])
        self.assertEqual(res['paired_nights'], 0)
        self.assertIsNone(res['mae'])
        self.assertIsNone(res['r'])
        self.assertIsNone(res['bias'])
        self.assertEqual(res['nights'][0]['observations']['records'], 0)
        text = vs.format_summary(res, show_nights=True)
        self.assertIn('NO OVERLAP', text)
        self.assertIn('offset_82_wins=N/A', text)
        self.assertIn('window_coverage=N/A', text)
        self.assertIn('no overlapping records', text)
        self.assertNotIn('window_coverage=PASS', text)

    def test_presence_categories_and_half_open_boundaries(self):
        with tempfile.TemporaryDirectory() as td:
            start = _utc(2025, 1, 1)
            rows = [(start-1, 99, 2), (start, 0, 2), (start+1, 97, 2),
                    (start+2, 160, 2), (start+3, 0, 2), (start+4, 99, 2)]
            db = _write_app_db(td, rows)
            with sqlite3.connect(db) as conn:
                conn.execute('UPDATE v18AuxSample SET fields=? WHERE ts=?',
                             (b'\x02\x00\x00\x00\x00', start+3))
            export = _write_export(td, [('2025-01-01 00:00:00', 97, start, start+4)])
            res = vs.validate_device(db, export)
        night = res['nights'][0]
        self.assertFalse(night['no_overlap'])
        self.assertEqual(night['observations'], dict(records=4, recorded_seconds=4,
                         missing=1, zero=1, inband=1, out_of_range=1))
        self.assertEqual(night['candidate_mean'], 97)

    def test_recorded_zero_is_not_no_overlap(self):
        with tempfile.TemporaryDirectory() as td:
            start = _utc(2025, 1, 1)
            db = _write_app_db(td, [(start+i, 0, 2) for i in range(30)])
            export = _write_export(td, [('2025-01-01 00:00:00', 97, start, start+30)])
            res = vs.validate_device(db, export)
        self.assertNotEqual(res['classification'], 'no_overlap')
        self.assertEqual(res['nights'][0]['observations']['zero'], 30)
        self.assertIsNone(res['nights'][0]['candidate_mean'])


if __name__ == '__main__':
    unittest.main()

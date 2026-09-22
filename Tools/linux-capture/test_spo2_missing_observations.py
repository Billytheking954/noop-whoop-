"""Regression tests: missing banked @82 must not prove feature absence."""
from contextlib import closing
import sqlite3
import tempfile
import unittest

import validate_spo2_candidate as vs
from test_validate_spo2_candidate import _write_app_db, _write_export, _utc


class MissingObservationTests(unittest.TestCase):
    def test_british_summer_offset_matches_sensor_utc(self):
        expected = _utc(2026, 9, 11, 22)
        self.assertEqual(vs._parse_export_ts('2026-09-11 23:00:00', 'UTC+01:00'), expected)
        self.assertEqual(vs._parse_export_ts('2026-09-11T23:00:00+01:00'), expected)

    def test_cycle_loader_uses_timezone_column(self):
        import os
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'physiological_cycles.csv'), 'w') as f:
                f.write('Sleep onset,Wake onset,Cycle timezone,Blood oxygen %\n'
                        '2026-09-11 23:00:00,2026-09-12 07:00:00,UTC+01:00,97\n')
            row = vs.load_cycles(td)[0]
            self.assertEqual(row['t0'], _utc(2026, 9, 11, 22))
            self.assertEqual(row['t1'], _utc(2026, 9, 12, 6))

    def test_invalid_explicit_timezone_is_not_guessed(self):
        self.assertIsNone(vs._parse_export_ts('2026-09-11 23:00:00', 'unknown'))

    def test_missing_slot_survives_database_reader(self):
        with tempfile.TemporaryDirectory() as td:
            path = _write_app_db(td, [(100, 0, 2)])
            # A sqlite3 connection context commits/rolls back but does not close.
            # Close explicitly so Windows can remove the temporary database.
            with closing(sqlite3.connect(path)) as db:
                db.execute("UPDATE v18AuxSample SET fields=?", (b'\x02\x00\x00\x00\x00',))
                db.commit()
            row = vs.load_app_db_records(path)[0]
            self.assertIsNone(row['aux_byte_82'])
            self.assertIsNone(vs.byte_at_offset(row, 82))

    def test_all_missing_is_unknown_not_zero(self):
        duty = vs.detect_duty_cycle([dict(unix=i, aux_byte_82=None) for i in range(4000)])
        self.assertEqual(duty['mode'], 'unknown')
        self.assertEqual(duty['n_records'], 0)
        self.assertEqual(duty['n_missing'], 4000)

    def test_missing_does_not_dilute_nonzero_fraction(self):
        rows = [dict(unix=i, aux_byte_82=96 if i < 10 else None) for i in range(100)]
        duty = vs.detect_duty_cycle(rows)
        self.assertEqual(duty['mode'], 'continuous')
        self.assertEqual(duty['nonzero_fraction'], 1)

    def test_missing_samples_do_not_cover_duty_window(self):
        duty = dict(mode='duty_cycled', period_s=1200, phase_s=0, window_len_s=30)
        covered, expected = vs.night_window_coverage([dict(unix=5, aux_byte_82=None)], 0, 1200, duty)
        self.assertEqual((covered, expected), (0, 1))

    def test_corrupt_blobs_cannot_establish_feature_absence(self):
        with tempfile.TemporaryDirectory() as td:
            start = _utc(2026, 8, 1)
            path = _write_app_db(td, [(start+i, 0, 2) for i in range(4000)])
            with closing(sqlite3.connect(path)) as db:
                db.execute("UPDATE v18AuxSample SET fields=?", (b'\xff',))
                db.commit()
            export = _write_export(td, [('2026-08-01 00:00:00', 97, start, start+4000)])
            result = vs.validate_device(path, export)
            self.assertNotEqual(result['classification'], 'feature_absent')
            self.assertEqual(result['observed_asleep_s'], 0)
            self.assertIn('missing or undecodable', '\n'.join(vs.coverage_warnings(result)))


if __name__ == '__main__':
    unittest.main()

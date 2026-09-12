import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("whoop_trial", Path(__file__).with_name("whoop_trial.py"))
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


class TrialTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def fixture(self):
        path = self.root / "snapshot.sqlite"
        db = sqlite3.connect(path)
        db.executescript('''
            CREATE TABLE sleepSession(deviceId TEXT,startTs INT,endTs INT,stagesJSON TEXT,userEdited INT,startTsAdjusted INT);
            CREATE TABLE hrSample(deviceId TEXT,ts INT,bpm INT);
            CREATE TABLE ppgHrSample(deviceId TEXT,ts INT,bpm REAL,conf REAL);
            CREATE TABLE gravitySample(deviceId TEXT,ts INT,x REAL,y REAL,z REAL);
            CREATE TABLE rrInterval(deviceId TEXT,ts INT,rrMs INT,srcChannel INT);
        ''')
        stages = [dict(start=0,end=30,stage="light"),dict(start=30,end=60,stage="wake")]
        db.execute("INSERT INTO sleepSession VALUES (?,?,?,?,?,?)", ("computed",0,60,json.dumps(stages),0,None))
        db.executemany("INSERT INTO hrSample VALUES ('raw',?,60)", [(0,), (1,)])
        db.executemany("INSERT INTO ppgHrSample VALUES ('raw',?,61,.9)", [(1,), (2,)])
        db.executemany("INSERT INTO gravitySample VALUES ('raw',?,0,0,1)", [(0,), (1,), (20,)])
        db.commit()
        db.close()
        return path

    def test_readonly_and_input_unchanged(self):
        path = self.fixture()
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        db = trial.open_snapshot(path)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("DELETE FROM sleepSession")
        self.assertEqual(len(trial.sessions(db, "computed")), 1)
        db.close()
        self.assertEqual(before, hashlib.sha256(path.read_bytes()).hexdigest())

    def test_sidecars_rejected(self):
        path = self.fixture()
        Path(str(path) + "-wal").touch()
        with self.assertRaises(ValueError):
            trial.open_snapshot(path)

    def test_coverage_missing_and_measured_precedence(self):
        db = trial.open_snapshot(self.fixture())
        self.addCleanup(db.close)
        c = trial.coverage(db, "raw", 0, 60)
        self.assertEqual(c["hr_union_coverage"], 3/60)
        self.assertEqual(c["hr_ppg_only_coverage"], 1/60)
        self.assertEqual(c["motion_adjacent_pairs_coverage"], 1/60)
        self.assertEqual(c["rr_raw_coverage"], 0)
        self.assertIsNone(c["resp_raw_coverage"])

    def test_device_parameter_is_literal(self):
        db = trial.open_snapshot(self.fixture())
        self.addCleanup(db.close)
        self.assertEqual(trial.sessions(db, "computed' OR 1=1 --"), [])

    def test_gapped_stages_not_filled(self):
        path = self.fixture()
        db = sqlite3.connect(path)
        db.execute("UPDATE sleepSession SET stagesJSON=?", (json.dumps([dict(start=0,end=30,stage="light")]),))
        db.commit()
        db.close()
        db = trial.open_snapshot(path)
        self.addCleanup(db.close)
        row = trial.sessions(db,"computed")[0]
        self.assertIsNone(row["metrics"]["asleep_min"])
        self.assertIsNotNone(row["issue"])

    def test_pairing_ambiguity_is_withheld(self):
        ns = [dict(start=0,end=60),dict(start=0,end=60)]
        pairs, ambiguous = trial.pair(ns,[dict(start=0,end=60)])
        self.assertEqual(pairs,[])
        self.assertEqual(ambiguous,[0,1])

    def test_timezone_and_midnight(self):
        self.assertEqual(trial.timestamp("2026-09-12 00:30:00", "UTC+01:00"),
                         trial.timestamp("2026-09-11T23:30:00Z", ""))
        with self.assertRaises(ValueError):
            trial.timestamp("2026-09-12 00:30:00", "")

    def test_csv_zip_missing_and_zero(self):
        path = self.root / "export.zip"
        data = ("Sleep onset,Wake onset,Cycle timezone,Light sleep duration (min),REM duration (min),Nap\n"
                "2026-09-11 23:00:00,2026-09-12 07:00:00,UTC+01:00,0,,false\n")
        with zipfile.ZipFile(path,"w") as z:
            z.writestr("nested/sleeps.csv",data)
        rows, digest = trial.read_whoop(path)
        self.assertEqual(rows[0]["metrics"]["light_min"],0)
        self.assertIsNone(rows[0]["metrics"]["rem_min"])
        self.assertEqual(rows[0]["end"]-rows[0]["start"],8*3600)
        self.assertEqual(digest,hashlib.sha256(data.encode()).hexdigest())

    def test_duplicate_export_rejected(self):
        path = self.root / "sleeps.csv"
        row = "2026-09-11T23:00:00Z,2026-09-12T07:00:00Z\n"
        path.write_text("Sleep onset,Wake onset\n"+row+row)
        with self.assertRaises(ValueError):
            trial.read_whoop(path)

    def test_aggregate_bias_and_undefined_correlation(self):
        s = trial.stats([(3,1),(1,3)])
        self.assertEqual(s["mae"],2)
        self.assertEqual(s["bias"],0)
        self.assertIsNone(s["correlation"])
        self.assertIsNone(trial.stats([])["mae"])

    def test_end_to_end_metrics_and_json(self):
        db = trial.open_snapshot(self.fixture())
        self.addCleanup(db.close)
        metrics = dict.fromkeys(trial.FIELDS)
        metrics.update(asleep_min=.5,in_bed_min=1,light_min=.5,deep_min=0,rem_min=0,awake_min=.5,efficiency_pct=50)
        report = trial.compare(db,"computed","raw",[dict(start=0,end=60,nap=False,metrics=metrics)])
        self.assertEqual(report["matched"],1)
        self.assertEqual(report["summary"]["asleep_min"]["mae"],0)
        self.assertEqual(report["summary"]["awake_share_pct"]["bias"],0)
        json.dumps(report,allow_nan=False)

    def test_edited_sessions_excluded_from_aggregate(self):
        path = self.fixture()
        db = sqlite3.connect(path)
        db.execute("UPDATE sleepSession SET userEdited=1")
        db.commit()
        db.close()
        db = trial.open_snapshot(path)
        self.addCleanup(db.close)
        report = trial.compare(db,"computed","raw",[dict(start=0,end=60,nap=False,metrics=dict.fromkeys(trial.FIELDS))])
        self.assertEqual(report["matched"],1)
        self.assertEqual(report["summary"]["onset_error_min"]["n"],0)


if __name__ == "__main__":
    unittest.main()

"""Synthetic backup integrity tests: no user exports or physiological values."""
from contextlib import closing
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from backup_validation import BackupValidationError, open_verified_database, snapshot_path


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / 'source.sqlite'
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript('CREATE TABLE t(x,y); INSERT INTO t VALUES(1,20),(2,10); CREATE INDEX ix ON t(x);')
            db.commit()

    def archive(self):
        path = self.root / 'backup.noopbak'
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as z:
            z.write(self.db, 'noop-backup.sqlite')
            z.writestr('manifest.json', '{}')
        return path

    def test_roundtrip_readonly_and_cleanup(self):
        path = self.archive(); before = path.read_bytes()
        with snapshot_path(path) as extracted:
            db = open_verified_database(extracted)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM t').fetchone()[0], 2)
            with self.assertRaises(sqlite3.OperationalError): db.execute('DELETE FROM t')
            db.close()
        self.assertFalse(extracted.exists())
        self.assertEqual(path.read_bytes(), before)

    def test_truncated_archive_rejected(self):
        path = self.archive(); path.write_bytes(path.read_bytes()[:-30])
        with self.assertRaises(BackupValidationError), snapshot_path(path): pass

    def test_bad_crc_rejected(self):
        path = self.archive(); body = bytearray(path.read_bytes())
        name_len, extra_len = struct.unpack_from('<HH', body, 26)
        body[30 + name_len + extra_len + 100] ^= 1
        path.write_bytes(body)
        with self.assertRaises(BackupValidationError), snapshot_path(path): pass

    def test_full_check_catches_index_mismatch_quick_check_misses(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('PRAGMA writable_schema=ON')
            db.execute("UPDATE sqlite_master SET sql='CREATE INDEX ix ON t(y)' WHERE name='ix'")
            db.commit()
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute('PRAGMA quick_check').fetchall(), [('ok',)])
        before = self.db.read_bytes()
        with self.assertRaisesRegex(BackupValidationError, 'integrity'):
            open_verified_database(self.db)
        self.assertEqual(before, self.db.read_bytes())

    def test_corrupt_database_inside_valid_archive_rejected(self):
        body = bytearray(self.db.read_bytes()); body[100] = 0
        self.db.write_bytes(body)
        with self.assertRaises(BackupValidationError), snapshot_path(self.archive()) as path:
            open_verified_database(path)

    def test_sidecars_rejected_without_mutation(self):
        sidecar = Path(str(self.db)+'-wal');sidecar.write_bytes(b'pending')
        with self.assertRaisesRegex(BackupValidationError, 'sidecars'):
            open_verified_database(self.db)
        self.assertEqual(sidecar.read_bytes(), b'pending')

    def test_foreign_key_violation_rejected(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript('CREATE TABLE p(id PRIMARY KEY); CREATE TABLE c(pid REFERENCES p(id)); INSERT INTO c VALUES(1);')
            db.commit()
        with self.assertRaisesRegex(BackupValidationError, 'foreign-key'):
            open_verified_database(self.db)

    def test_sqlite_open_failure_is_normalized(self):
        with patch('backup_validation.sqlite3.connect', side_effect=sqlite3.DatabaseError('open failed')):
            with self.assertRaisesRegex(BackupValidationError, 'validation failed'):
                open_verified_database(self.db)

    def test_paths_and_duplicate_databases_rejected(self):
        for names in [('noop-backup.sqlite','../outside'),('nested/noop-backup.sqlite',),
                      ('noop-backup.sqlite','noop-backup.sqlite')]:
            path = self.root/'bad.noopbak'
            with zipfile.ZipFile(path,'w') as z:
                for name in names:z.writestr(name,self.db.read_bytes())
            with self.assertRaises(BackupValidationError), snapshot_path(path):pass
        self.assertFalse((self.root.parent/'outside').exists())

    def test_resource_limit_rejected(self):
        with self.assertRaisesRegex(BackupValidationError, 'size limit'), snapshot_path(self.archive(), max_database_bytes=100):pass

    def test_non_database_input_rejected(self):
        self.db.write_bytes(b'not sqlite')
        with self.assertRaises(BackupValidationError):open_verified_database(self.db)


if __name__ == '__main__':unittest.main()

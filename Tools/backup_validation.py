"""Read-only preflight for standalone databases and NOOP backup archives.

Never point immutable SQLite readers at a live store. Archive extraction uses a
private temporary directory, fixed output names and bounded streaming reads.
"""
from contextlib import contextmanager
from collections.abc import Iterator, Mapping
from pathlib import Path
import sqlite3
import tempfile
import zipfile


class BackupValidationError(ValueError):
    pass


def open_verified_database(path: str | Path) -> sqlite3.Connection:
    path = Path(path).resolve(strict=True)
    if any(Path(str(path) + suffix).exists() for suffix in ('-wal', '-shm', '-journal')):
        raise BackupValidationError('Use a standalone exported database without sidecars, never a live store')
    with path.open('rb') as source:
        if source.read(16) != b'SQLite format 3\x00':
            raise BackupValidationError('Input is not a SQLite database')
    try:
        db = sqlite3.connect(path.as_uri() + '?mode=ro&immutable=1', uri=True)
    except sqlite3.Error as exc:
        raise BackupValidationError('SQLite validation failed; comparison refused') from exc
    try:
        db.execute('PRAGMA query_only=ON')
        # quick_check misses some index/content disagreements; require the full check.
        if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise BackupValidationError('SQLite integrity check failed; comparison refused')
        if db.execute('PRAGMA foreign_key_check').fetchone() is not None:
            raise BackupValidationError('SQLite foreign-key check failed; comparison refused')
        return db
    except sqlite3.Error as exc:
        db.close()
        raise BackupValidationError('SQLite validation failed; comparison refused') from exc
    except BaseException:
        db.close()
        raise


@contextmanager
def snapshot_path(path: str | Path, *, max_database_bytes: int = 8 * 1024**3) -> Iterator[Path]:
    """Resolve a plain database or extract one canonical .noopbak database.

    Extraction checks CRCs for every supported archive entry, but does not open
    SQLite. Call open_verified_database on the yielded path before reading data.
    The 8 GiB tooling ceiling accommodates backups larger than the app's 2 GiB
    restore warning. It is a resource limit, not an assessment of data quality.
    """
    path = Path(path).resolve(strict=True)
    with path.open('rb') as source:
        magic = source.read(4)
    if path.suffix.lower() not in ('.noopbak', '.zip') and magic != b'PK\x03\x04':
        yield path
        return
    limits = {'noop-backup.sqlite': max_database_bytes,
              'manifest.json': 1024**2, 'settings.json': 1024**2}
    with tempfile.TemporaryDirectory(prefix='noop-validated-') as temporary:
        target = Path(temporary) / 'noop-backup.sqlite'
        try:
            _extract_archive(path, target, limits)
        except (zipfile.BadZipFile, EOFError, RuntimeError) as exc:
            raise BackupValidationError('Backup archive is truncated, corrupt or unreadable') from exc
        # Errors in the consumer must not be relabelled as archive corruption.
        yield target


def _extract_archive(path: Path, target: Path, limits: Mapping[str, int]) -> None:
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if (len(names) != len(set(names)) or names.count('noop-backup.sqlite') != 1
                or any(name not in limits for name in names)):
            raise BackupValidationError('Expected one canonical NOOP database and optional JSON metadata')
        for entry in entries:
            if entry.file_size > limits[entry.filename]:
                raise BackupValidationError('Backup entry exceeds the analysis size limit')
            total = 0
            with archive.open(entry) as source:
                with (target.open('wb') if entry.filename == 'noop-backup.sqlite'
                      else tempfile.TemporaryFile()) as output:
                    while chunk := source.read(1024**2):
                        total += len(chunk)
                        if total > limits[entry.filename]:
                            raise BackupValidationError('Expanded backup exceeds the analysis size limit')
                        output.write(chunk)
            if total != entry.file_size:
                raise BackupValidationError('Backup entry length mismatch')

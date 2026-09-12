# Backup preflight for physiological comparisons

Both `SleepBench/whoop_trial.py` and `linux-capture/validate_spo2_candidate.py`
accept a standalone SQLite database or a canonical `.noopbak` archive. They
share `backup_validation.py`; keep the repository's Tools directory structure
when running either script. Capture JSON inputs remain supported by the SpO2 tool.

Before a database is compared:

1. A backup archive must have exactly one `noop-backup.sqlite`, with optional
   `settings.json` and `manifest.json`. Duplicate or other member names fail.
2. Every accepted member is streamed to EOF with CRC and length verification.
   Extraction uses fixed filenames in a temporary directory; paths from the
   archive are never used as output paths. Temporary files are removed on exit.
3. The SQLite member is limited to 8 GiB and each metadata member to 1 MiB.
   This analysis limit accommodates databases above the app's restore warning.
   Unknown archive layouts are rejected, not guessed.
4. Plain databases with WAL, SHM or journal sidecars are rejected. Supply an
   exported standalone snapshot, never a live database.
5. SQLite is opened with `mode=ro&immutable=1` and `query_only=ON`. Full
   `integrity_check` must return only `ok`; `foreign_key_check` must return no
   violations. No repair is attempted. The full check intentionally catches
   index/content inconsistencies that `quick_check` can miss.

An integrity failure prevents comparison. Passing preflight establishes database
structure, not complete sensor coverage, correct device identity or accuracy.
It does not make a live file safe to read as immutable: the caller must supply a
stable export. JSON metadata is CRC-checked, not interpreted as an app-version or
device-authenticity guarantee. Errors and resource failures leave inputs alone.

## Commands

```sh
python3 Tools/SleepBench/whoop_trial.py --db backup.noopbak --whoop export.zip \
  --device COMPUTED_OWNER --stream-device RAW_OWNER --out private-comparison.json
python3 Tools/linux-capture/validate_spo2_candidate.py backup.noopbak export.zip
python3 -m unittest discover -s Tools -p test_backup_validation.py
python3 -m unittest discover -s Tools/SleepBench -p 'test_*.py'
python3 -m unittest discover -s Tools/linux-capture -p 'test_*.py'
```

Tests use synthetic databases and archives, including CRC damage, truncation,
an index mismatch that passes quick_check, foreign-key violations, sidecars,
resource limits, duplicate/path entries, archive integration and read-only
preservation. Some repository suites require optional local capture fixtures.

## Apple backup writer audit

At source baseline `63d5bff73df44b771698e9488884a795bb82ee00`,
`Strand/Data/DataBackup.swift` checkpoints before exporting and runs a source
quick_check, then compresses the live database path. `verifyWrittenBackup(at:)`
opens the ZIP central directory and checks for a database entry of at least
100 bytes. It does not extract/CRC-check that entry or check its SQLite content.
The write-integrity tests deliberately use non-database random payloads with a
SQLite header, so those tests establish container structure only.

These verified code properties expose a possible concurrent-change gap between
checkpoint/check and the archive read. They do not establish the cause of any
particular damaged export. This tooling change does not modify the app writer.

Before changing the writer, reproduce export during active ingestion and
checkpointing. The proposed correction is to use SQLite's backup API (or the
corresponding GRDB backup operation) to create a consistent isolated snapshot,
validate that snapshot, archive it, and validate the archived database before
reporting success. Verify failure handling, cancellation, low disk space and
preservation of earlier backups in the Apple test environment. Do not substitute
a file copy of the live SQLite file for the snapshot operation.

No sleep, oxygen, RHR or HRV algorithm is changed by this preflight.

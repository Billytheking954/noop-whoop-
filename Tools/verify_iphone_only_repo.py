#!/usr/bin/env python3
"""Fail CI if retired product platforms or release paths return."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
errors = []

for rel in ("android", "NOOPWatch", "NOOPWatchComplications", "Strand.xcodeproj"):
    if (ROOT / rel).exists():
        errors.append(f"retired product path exists: {rel}")

for rel in (
    ".github/workflows/android.yml",
    ".github/workflows/fork-release.yml",
    ".github/workflows/fork-testing-build.yml",
    ".github/workflows/parity-governance.yml",
):
    if (ROOT / rel).exists():
        errors.append(f"obsolete workflow exists: {rel}")

project = (ROOT / "project.yml").read_text(encoding="utf-8")
required = (
    'platform: iOS',
    'TARGETED_DEVICE_FAMILY: "1"',
    'NOOPiOS:',
    'NOOPiOSWidgets:',
)
for needle in required:
    if needle not in project:
        errors.append(f"project.yml missing required invariant: {needle}")

for forbidden in (
    'platform: macOS',
    'platform: watchOS',
    'TARGETED_DEVICE_FAMILY: "1,2"',
    'NOOPWatch:',
    'NOOPWatchComplications:',
):
    if forbidden in project:
        errors.append(f"project.yml contains retired platform invariant: {forbidden}")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print("iPhone-only repository invariants: PASS")

#!/usr/bin/env python3
"""Fail CI if retired product platforms or obsolete distribution paths return."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
errors = []

retired_paths = (
    "android",
    "NOOPWatch",
    "NOOPWatchComplications",
    "Strand.xcodeproj",
    "altstore-source.json",
    "docs/ANDROID.md",
    "docs/CROSS_PLATFORM.md",
    "docs/HOMEBREW.md",
    "Tools/PARITY_GOVERNANCE.md",
    "Tools/parity_cases",
    "Tools/parity_dispositions.json",
    "Tools/parity_ledger.py",
    "Tools/parity_ledger_baseline.json",
    "Tools/parity_ratchet.py",
    "Tools/parity_twin_map.json",
    "Tools/anonymize-macos-app.sh",
    "Tools/update-homebrew-cask.sh",
    "Tools/release.sh",
    "Tools/forgejo-release.sh",
    "Tools/build-v7-artifacts.sh",
    "Tools/update-altstore-source.sh",
    "Tools/prepare-ios-sideload-app.sh",
)
for rel in retired_paths:
    if (ROOT / rel).exists():
        errors.append(f"retired product/distribution path exists: {rel}")

obsolete_workflows = (
    ".github/workflows/android.yml",
    ".github/workflows/fork-release.yml",
    ".github/workflows/fork-testing-build.yml",
    ".github/workflows/parity-governance.yml",
)
for rel in obsolete_workflows:
    if (ROOT / rel).exists():
        errors.append(f"obsolete workflow exists: {rel}")

project_path = ROOT / "project.yml"
if not project_path.is_file():
    errors.append("project.yml is missing")
    project = ""
else:
    project = project_path.read_text(encoding="utf-8")

required = (
    'platform: iOS',
    'TARGETED_DEVICE_FAMILY: "1"',
    'NOOPiOS:',
    'NOOPiOSWidgets:',
    'StrandTests:',
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
    'type: application.watchapp2',
):
    if forbidden in project:
        errors.append(f"project.yml contains retired platform invariant: {forbidden}")

if project.count('type: application\n') != 1:
    errors.append("project.yml must define exactly one end-user application target")
if project.count('type: app-extension\n') != 1:
    errors.append("project.yml must define exactly one required app extension target")

release_workflow = ROOT / ".github/workflows/iphone-final-release.yml"
if not release_workflow.is_file():
    errors.append("authoritative iPhone final-release workflow is missing")

scope_lock = ROOT / ".github/release/iphone-v2-final.json"
if not scope_lock.is_file():
    errors.append("V2 release scope lock is missing")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print("iPhone-only repository invariants: PASS")

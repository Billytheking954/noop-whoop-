#!/usr/bin/env python3
"""Verify a final NOOP iPhone IPA before it may be published.

This intentionally validates identity/provenance, not just ZIP readability.  The
release workflow calls it only after the app has been freshly built and signed.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
import zipfile
from pathlib import Path, PurePosixPath


def fail(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_member(zf: zipfile.ZipFile, name: str) -> bytes:
    try:
        data = zf.read(name)
    except KeyError:
        fail(f"missing required IPA member: {name}")
    if not data:
        fail(f"required IPA member is empty: {name}")
    return data


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--baseline", default="NOOP 11.8")
    parser.add_argument("--release-family", default="NOOP V2")
    parser.add_argument("--expected-filename")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ipa = args.ipa

    if not ipa.is_file():
        fail(f"IPA does not exist: {ipa}")
    if ipa.suffix.lower() != ".ipa":
        fail(f"artifact is not an .ipa: {ipa.name}")
    if args.expected_filename and ipa.name != args.expected_filename:
        fail(f"artifact filename mismatch: {ipa.name!r} != {args.expected_filename!r}")

    try:
        zf = zipfile.ZipFile(ipa, "r")
    except zipfile.BadZipFile as exc:
        fail(f"IPA is not a valid ZIP archive: {exc}")

    with zf:
        bad = zf.testzip()
        if bad:
            fail(f"IPA CRC verification failed at member: {bad}")

        names = zf.namelist()
        if not names:
            fail("IPA archive is empty")

        # Reject path traversal or absolute members even though the verifier never extracts them.
        for raw in names:
            p = PurePosixPath(raw)
            if p.is_absolute() or ".." in p.parts:
                fail(f"unsafe path in IPA: {raw}")

        app_info_members = []
        for name in names:
            parts = PurePosixPath(name).parts
            if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == "Info.plist":
                app_info_members.append(name)
        if len(app_info_members) != 1:
            fail(f"expected exactly one Payload/<app>.app/Info.plist, found {len(app_info_members)}")

        info_name = app_info_members[0]
        app_root = str(PurePosixPath(info_name).parent)
        try:
            info = plistlib.loads(read_member(zf, info_name))
        except Exception as exc:  # plistlib raises several concrete parse errors.
            fail(f"cannot parse app Info.plist: {exc}")

        expected = {
            "CFBundleIdentifier": args.bundle_id,
            "CFBundleShortVersionString": args.version,
            "CFBundleVersion": args.build,
            "NOOPReleaseGitSHA": args.git_sha,
            "NOOPReleaseBaseline": args.baseline,
            "NOOPReleaseFamily": args.release_family,
        }
        for key, value in expected.items():
            actual = str(info.get(key, ""))
            if actual != str(value):
                fail(f"Info.plist {key} mismatch: {actual!r} != {value!r}")

        device_family = info.get("UIDeviceFamily")
        if device_family != [1]:
            fail(f"final artifact must target iPhone only; UIDeviceFamily is {device_family!r}")

        executable = info.get("CFBundleExecutable")
        if not executable:
            fail("CFBundleExecutable is missing")
        executable_member = f"{app_root}/{executable}"
        read_member(zf, executable_member)

        if any(name.startswith(f"{app_root}/Watch/") for name in names):
            fail("final iPhone IPA unexpectedly contains an embedded Watch app")
        if any("/MacOS/" in name for name in names):
            fail("final iPhone IPA unexpectedly contains a macOS bundle payload")

        # A final release must be signed/provisioned.  The workflow performs cryptographic
        # codesign verification too; these checks make it impossible to pass an unsigned
        # placeholder to this archive-level verifier.
        read_member(zf, f"{app_root}/embedded.mobileprovision")
        if not any(name.startswith(f"{app_root}/_CodeSignature/") for name in names):
            fail("app has no _CodeSignature directory")

        widget_root = f"{app_root}/PlugIns/NOOPWidgets.appex"
        widget_info_name = f"{widget_root}/Info.plist"
        try:
            widget_info = plistlib.loads(read_member(zf, widget_info_name))
        except Exception as exc:
            fail(f"cannot parse widget Info.plist: {exc}")
        if str(widget_info.get("CFBundleIdentifier", "")) != f"{args.bundle_id}.widgets":
            fail("widget bundle identifier does not match the released app bundle identifier")
        if str(widget_info.get("CFBundleShortVersionString", "")) != args.version:
            fail("widget marketing version does not match the app")
        if str(widget_info.get("CFBundleVersion", "")) != args.build:
            fail("widget build number does not match the app")
        read_member(zf, f"{widget_root}/embedded.mobileprovision")
        if not any(name.startswith(f"{widget_root}/_CodeSignature/") for name in names):
            fail("widget extension has no _CodeSignature directory")

        provenance_name = f"{app_root}/NOOPReleaseProvenance.json"
        try:
            provenance = json.loads(read_member(zf, provenance_name))
        except Exception as exc:
            fail(f"cannot parse embedded release provenance: {exc}")
        provenance_expected = {
            "product": "NOOP",
            "upstream_baseline": args.baseline,
            "git_sha": args.git_sha,
            "app_version": args.version,
            "build_number": args.build,
            "platform": "iOS",
            "device_family": "iPhone",
        }
        for key, value in provenance_expected.items():
            if str(provenance.get(key, "")) != str(value):
                fail(f"embedded provenance {key} mismatch: {provenance.get(key)!r} != {value!r}")

    result = {
        "artifact": ipa.name,
        "bundle_identifier": args.bundle_id,
        "version": args.version,
        "build": args.build,
        "git_sha": args.git_sha,
        "baseline": args.baseline,
        "release_family": args.release_family,
        "device_family": "iPhone",
        "archive_integrity": "verified",
        "provenance": "verified",
        "signed_bundle_markers": "present",
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

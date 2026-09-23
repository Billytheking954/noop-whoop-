import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "Tools" / "verify_iphone_ipa.py"


class VerifyIPhoneIPATests(unittest.TestCase):
    SHA = "a" * 40
    BUNDLE = "com.example.noop"
    VERSION = "11.8.0"
    BUILD = "400"
    FILENAME = "NOOP-V2-11.8-base-aaaaaaa-iphone.ipa"

    def make_ipa(self, directory: Path, *, sha: str | None = None, device_family=None, signed=True) -> Path:
        sha = sha or self.SHA
        if device_family is None:
            device_family = [1]
        ipa = directory / self.FILENAME
        app = "Payload/NOOP.app"
        widget = f"{app}/PlugIns/NOOPWidgets.appex"
        info = {
            "CFBundleIdentifier": self.BUNDLE,
            "CFBundleShortVersionString": self.VERSION,
            "CFBundleVersion": self.BUILD,
            "CFBundleExecutable": "NOOP",
            "UIDeviceFamily": device_family,
            "NOOPReleaseGitSHA": sha,
            "NOOPReleaseBaseline": "NOOP 11.8",
            "NOOPReleaseFamily": "NOOP V2",
        }
        widget_info = {
            "CFBundleIdentifier": f"{self.BUNDLE}.widgets",
            "CFBundleShortVersionString": self.VERSION,
            "CFBundleVersion": self.BUILD,
            "CFBundleExecutable": "NOOPWidgets",
        }
        provenance = {
            "product": "NOOP",
            "upstream_baseline": "NOOP 11.8",
            "git_sha": sha,
            "app_version": self.VERSION,
            "build_number": self.BUILD,
            "platform": "iOS",
            "device_family": "iPhone",
        }
        with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr(f"{app}/Info.plist", plistlib.dumps(info))
            zf.writestr(f"{app}/NOOP", b"not-a-real-mach-o-but-nonempty")
            zf.writestr(f"{app}/embedded.mobileprovision", b"profile")
            zf.writestr(f"{app}/NOOPReleaseProvenance.json", json.dumps(provenance))
            zf.writestr(f"{widget}/Info.plist", plistlib.dumps(widget_info))
            zf.writestr(f"{widget}/NOOPWidgets", b"extension")
            zf.writestr(f"{widget}/embedded.mobileprovision", b"profile")
            if signed:
                zf.writestr(f"{app}/_CodeSignature/CodeResources", b"signature")
                zf.writestr(f"{widget}/_CodeSignature/CodeResources", b"signature")
        return ipa

    def run_verifier(self, ipa: Path, *, expected_sha: str | None = None):
        return subprocess.run(
            [
                sys.executable,
                str(VERIFIER),
                str(ipa),
                "--bundle-id",
                self.BUNDLE,
                "--version",
                self.VERSION,
                "--build",
                self.BUILD,
                "--git-sha",
                expected_sha or self.SHA,
                "--baseline",
                "NOOP 11.8",
                "--release-family",
                "NOOP V2",
                "--expected-filename",
                self.FILENAME,
            ],
            text=True,
            capture_output=True,
        )

    def test_accepts_matching_signed_iphone_payload(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.run_verifier(self.make_ipa(Path(td)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"provenance": "verified"', result.stdout)

    def test_rejects_wrong_release_sha(self):
        with tempfile.TemporaryDirectory() as td:
            ipa = self.make_ipa(Path(td), sha="b" * 40)
            result = self.run_verifier(ipa)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("NOOPReleaseGitSHA mismatch", result.stderr)

    def test_rejects_ipad_capability_in_final_payload(self):
        with tempfile.TemporaryDirectory() as td:
            ipa = self.make_ipa(Path(td), device_family=[1, 2])
            result = self.run_verifier(ipa)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iPhone only", result.stderr)

    def test_rejects_unsigned_placeholder(self):
        with tempfile.TemporaryDirectory() as td:
            ipa = self.make_ipa(Path(td), signed=False)
            result = self.run_verifier(ipa)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("_CodeSignature", result.stderr)


if __name__ == "__main__":
    unittest.main()

"""Upgrade gates against the actual historical source, not a newly invented schema."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = '7acce06c3d22cb5dfe959f2c4a43902471d21332'


class UpgradeSourceTests(unittest.TestCase):
    def original(self, path):
        return subprocess.check_output(['git', 'show', f'{UPSTREAM}:{path}'], cwd=ROOT, text=True)

    def test_existing_v12_migration_definitions_are_unchanged(self):
        path = 'Packages/WhoopStore/Sources/WhoopStore/Database.swift'
        original = self.original(path)
        current = (ROOT / path).read_text()
        old_body = original[:original.rindex('        return migrator')]
        self.assertTrue(current.startswith(old_body), 'An existing v12 migration changed')

    def test_database_path_and_bluetooth_state_restore_identity_are_unchanged(self):
        path = 'Strand/Collect/StorePaths.swift'
        self.assertEqual((ROOT / path).read_text(), self.original(path), path)
        path = 'Strand/BLE/BLEManager.swift'
        current, original = (ROOT / path).read_text(), self.original(path)
        # A broadcast command may change without changing CoreBluetooth's restore
        # identity or the persisted peripheral selection used on reconnect.
        for pattern in [r'^\s*static let restoreID = .*$',
                        r'^.*CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID.*$',
                        r'^.*retrievePeripherals\(withIdentifiers:.*$']:
            self.assertEqual(re.findall(pattern, current, re.MULTILINE),
                             re.findall(pattern, original, re.MULTILINE), pattern)

    def test_archive_validator_rejects_staging_id(self):
        import verify_noop_upgrade as verifier
        from unittest.mock import patch
        with patch.object(verifier.Path, 'read_bytes', return_value=b'fixture'), \
             patch.object(verifier, 'UPSTREAM_SHA256', verifier.hashlib.sha256(b'fixture').hexdigest()), \
             patch.object(verifier, 'inspect', side_effect=[{'com.noopapp.noop': {}}, {'com.noopapp.rebuild.noop': {}}]):
            with self.assertRaisesRegex(AssertionError, 'identities differ'):
                verifier.compare('original', 'candidate')

    def test_quality_candidate_keeps_identity_but_drops_staging_product_name(self):
        project = (ROOT / 'project.yml').read_text()
        build = re.search(r'^\s*CURRENT_PROJECT_VERSION: "(\d+)"$', project, re.MULTILINE)
        self.assertIsNotNone(build)
        self.assertGreater(int(build.group(1)), 440)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: $(BUNDLE_ID_PREFIX).noop\n        PRODUCT_NAME: "NOOP"', project)
        self.assertNotIn('PRODUCT_NAME: "NOOP Staging"', project)
        self.assertIn('TEST_HOST: "$(BUILT_PRODUCTS_DIR)/NOOP.app/NOOP"', project)

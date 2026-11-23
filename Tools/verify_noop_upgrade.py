#!/usr/bin/env python3
"""Compare release identities; this is not proof of a physical SideStore update."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

UPSTREAM_SHA256 = 'e9c2c141ea7e2e40a4f6f38ae1c9e207f729c71a9488c8a21d751ce1618d0a5b'


def entitlements(binary):
    # Thin little-endian 64-bit Mach-O; fail closed on other formats.
    assert binary[:4] == b'\xcf\xfa\xed\xfe', 'Expected thin arm64 Mach-O'
    assert struct.unpack_from('<I', binary, 4)[0] == 0x100000c, 'Not arm64'
    offset = 32
    for _ in range(struct.unpack_from('<I', binary, 16)[0]):
        command, size = struct.unpack_from('<II', binary, offset)
        assert size >= 8
        if command == 0x1d:
            start, length = struct.unpack_from('<II', binary, offset + 8)
            blob = binary[start:start + length]
            magic, _, count = struct.unpack_from('>III', blob)
            assert magic == 0xfade0cc0
            for index in range(count):
                kind, entry = struct.unpack_from('>II', blob, 12 + 8 * index)
                if kind == 5:
                    magic, length = struct.unpack_from('>II', blob, entry)
                    assert magic == 0xfade7171
                    return plistlib.loads(blob[entry + 8:entry + length])
        offset += size
    return {}


def inspect(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'ZIP CRC failed'
        names = archive.namelist()
        assert len(names) == len(set(names)), 'Duplicate archive members'
        assert not any(n.startswith('/') or '..' in n.split('/') for n in names)
        roots = [n[:-10] for n in names if n.startswith('Payload/') and n.endswith('/Info.plist') and n.count('/') == 2]
        assert len(roots) == 1, 'Expected one app'
        root = roots[0]
        bundles = {}
        for name in names:
            if name == root + 'Info.plist' or (name.startswith(root + 'PlugIns/') and name.endswith('.appex/Info.plist')):
                info = plistlib.loads(archive.read(name))
                prefix = name[:-10]
                signature = entitlements(archive.read(prefix + info['CFBundleExecutable']))
                bundles[info['CFBundleIdentifier']] = {
                    'group': info.get('AppGroupIdentifier'),
                    'version': info['CFBundleShortVersionString'],
                    'build': info['CFBundleVersion'],
                    'entitlements': signature,
                }
        assert not any(n.endswith('embedded.mobileprovision') for n in names), 'Personal profile embedded'
        assert not any('/Watch/' in n for n in names), 'Unexpected Watch payload'
        return bundles


def compare(original, candidate):
    assert hashlib.sha256(Path(original).read_bytes()).hexdigest() == UPSTREAM_SHA256, 'Unrecognised upstream IPA'
    old, new = inspect(original), inspect(candidate)
    assert set(old) == set(new), 'App/extension identities differ'
    assert set(old) == {'com.noopapp.noop', 'com.noopapp.noop.widgets'}
    for identifier in old:
        before, after = old[identifier], new[identifier]
        assert before['group'] == after['group'] == 'group.com.noopapp.noop.staging', 'App Group changed'
        assert int(after['build']) > int(before['build']), 'Build did not increase'
        assert after['entitlements'].get('com.apple.security.application-groups') == [before['group']], 'Missing group entitlement'
        assert not after['entitlements'].get('com.apple.developer.team-identifier'), 'Personal team embedded'
    assert len({b['build'] for b in new.values()}) == 1
    assert len({b['version'] for b in new.values()}) == 1
    for key in ['com.apple.developer.healthkit', 'com.apple.developer.healthkit.background-delivery']:
        assert new['com.noopapp.noop']['entitlements'].get(key) is True, key
    return {'original_sha256': UPSTREAM_SHA256, 'candidate_sha256': hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
            'original': old, 'candidate': new, 'source_identity_matches': True,
            'installed_signed_identity_verified': False, 'physical_update_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original')
    parser.add_argument('candidate')
    parser.add_argument('--output')
    args = parser.parse_args()
    report = json.dumps(compare(args.original, args.candidate), indent=2, sort_keys=True) + '\n'
    if args.output:
        Path(args.output).write_text(report)
    print(report)

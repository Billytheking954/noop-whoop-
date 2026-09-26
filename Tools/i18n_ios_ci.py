#!/usr/bin/env python3
"""Strict iPhone-only localisation gate for NOOP V2.

This intentionally reuses the mature Apple scanners from i18n_audit.py while
leaving retired Android/watch product catalog checks out of supported-product CI.
"""
from __future__ import annotations

import sys

import i18n_audit as audit


def main() -> int:
    failed = False

    # The inherited audit module also knows about the retired watch products.
    # Restrict its Apple scan to catalogs that actually remain in the iPhone
    # product instead of treating deleted watch catalogs as missing files.
    audit.CATALOGS = [
        (dirs, catalog_path)
        for dirs, catalog_path in audit.CATALOGS
        if catalog_path.is_file()
    ]
    if not audit.CATALOGS:
        print("FAIL no retained Apple localization catalogs found")
        return 1

    baseline = audit.load_baseline()

    print("--- iPhone: no new un-extracted UI copy ---")
    ios_literals, _ = audit.scan_ios()
    ios_found = {(p, lit) for p, _line, lit in ios_literals}
    ios_new = [f for f in ios_literals if (f[0], f[2]) not in baseline["ios"]]
    if ios_new:
        failed = True
        print(f"FAIL {len(ios_new)} new literal(s) absent from their target catalog:")
        for path, line, literal in ios_new[:30]:
            print(f"  {path}:{line}: {literal!r}")
    else:
        print(f"  OK no new un-extracted literals ({len(ios_found)} pre-existing baseline entries)")

    print("\n--- iPhone: focus locales complete and format-safe ---")
    for _dirs, catalog_path in audit.CATALOGS:
        cat = audit.load_catalog(catalog_path)
        for lang in audit.LANGS:
            missing = sum(
                1
                for value in cat.get("strings", {}).values()
                if value.get("shouldTranslate") is not False
                and not audit._is_translated(value, lang)
            )
            if missing:
                failed = True
                print(f"FAIL {catalog_path.relative_to(audit.ROOT)} {lang}: missing={missing}")
            else:
                print(f"  OK {catalog_path.relative_to(audit.ROOT)} {lang}")

            format_gaps = audit.apple_format_gaps(cat, lang)
            if format_gaps:
                failed = True
                print(
                    f"FAIL {catalog_path.relative_to(audit.ROOT)} {lang}: "
                    f"{len(format_gaps)} format mismatch(es): {format_gaps[:10]}"
                )

        for lang in sorted(audit.shipped_apple_langs(cat) - set(audit.LANGS)):
            format_gaps = audit.apple_format_gaps(cat, lang)
            if format_gaps:
                failed = True
                print(
                    f"FAIL {catalog_path.relative_to(audit.ROOT)} {lang}: "
                    f"{len(format_gaps)} format mismatch(es): {format_gaps[:10]}"
                )

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

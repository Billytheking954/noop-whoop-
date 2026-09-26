#!/usr/bin/env bash
# Preserve the app and widget capabilities for a sideloader that re-signs this IPA.
# The ad-hoc signatures below do not make this IPA installable by themselves.
set -euo pipefail

APP="${1:?usage: $0 path/to/NOOP.app}"
WIDGET="$APP/PlugIns/NOOPWidgets.appex"
test -d "$APP" && test -d "$WIDGET"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$APP/Info.plist")"
WIDGET_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$WIDGET/Info.plist")"
test -n "$APP_GROUP" && test "$APP_GROUP" = "$WIDGET_GROUP"

python3 - "$ROOT" "$APP_GROUP" <<'PY'
import pathlib, plistlib, sys
root, group = pathlib.Path(sys.argv[1]), sys.argv[2]
entitlements = {
    'com.apple.security.application-groups': [group],
}
with (root/'widget.plist').open('wb') as f:
    plistlib.dump(entitlements, f)
entitlements['com.apple.developer.healthkit'] = True
entitlements['com.apple.developer.healthkit.access'] = []
with (root/'app.plist').open('wb') as f:
    plistlib.dump(entitlements, f)
PY

codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements "$ROOT/widget.plist" "$WIDGET"
codesign --force --sign - --entitlements "$ROOT/app.plist" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > "$ROOT/signed-app.plist" 2>/dev/null
codesign -d --entitlements :- "$WIDGET" > "$ROOT/signed-widget.plist" 2>/dev/null
python3 - "$ROOT" "$APP_GROUP" <<'PY'
import pathlib, plistlib, sys
root, group = pathlib.Path(sys.argv[1]), sys.argv[2]
for name in ('signed-app.plist', 'signed-widget.plist'):
    with (root/name).open('rb') as f:
        entitlements = plistlib.load(f)
    assert group in entitlements['com.apple.security.application-groups'], name
with (root/'signed-app.plist').open('rb') as f:
    assert plistlib.load(f)['com.apple.developer.healthkit'] is True
PY

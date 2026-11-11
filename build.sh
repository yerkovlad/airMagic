#!/bin/zsh
# Builds AirMagic.app, signs it with a stable identity requirement (so the
# Accessibility and Bluetooth permissions survive rebuilds), and runs the
# offline self-test.
set -euo pipefail
cd -- "${0:A:h}"

APP=AirMagic.app
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc -swift-version 5 -O Sources/*.swift -o "$OUT/AirMagic" \
    -framework AppKit -framework CoreBluetooth -framework IOBluetooth -framework ApplicationServices

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
mv -f "$OUT/AirMagic" "$APP/Contents/MacOS/AirMagic"
codesign --force --sign - -i local.airmagic -r='designated => identifier "local.airmagic"' "$APP"

"$APP/Contents/MacOS/AirMagic" --self-test
echo "Built $PWD/$APP"

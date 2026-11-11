#!/bin/zsh
# Builds AirMagic and puts it in /Applications, so it opens like any other app
# (Launchpad, Spotlight, Dock). Opening it again while it runs connects.
set -euo pipefail
cd -- "${0:A:h}"
zsh ./build.sh
pkill -x AirMagic 2>/dev/null || true
rm -rf /Applications/AirMagic.app
cp -R AirMagic.app /Applications/AirMagic.app
open -n /Applications/AirMagic.app
echo "Installed /Applications/AirMagic.app"

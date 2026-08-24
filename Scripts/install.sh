#!/bin/bash
# Installs Inkstone: the app into /Applications, the CLI onto your PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="${INKSTONE_APP_DIR:-$HOME/Applications}"
BIN_DIR="${INKSTONE_BIN_DIR:-/usr/local/bin}"

"$ROOT/Scripts/build-app.sh" release

mkdir -p "$APPS"
rm -rf "$APPS/Inkstone.app"
cp -R "$ROOT/dist/Inkstone.app" "$APPS/Inkstone.app"
echo "Installed $APPS/Inkstone.app"

if [ -w "$BIN_DIR" ] || mkdir -p "$BIN_DIR" 2>/dev/null; then
    ln -sf "$APPS/Inkstone.app/Contents/Resources/inkstone" "$BIN_DIR/inkstone"
    echo "Linked $BIN_DIR/inkstone"
else
    echo "Cannot write $BIN_DIR. Either re-run with sudo, or add this to your shell profile:"
    echo "  alias inkstone='$APPS/Inkstone.app/Contents/Resources/inkstone'"
fi

echo
echo "Next:"
echo "  inkstone init      # write a config file"
echo "  inkstone doctor    # check the setup"
echo "  open -a Inkstone   # start the menu-bar app"

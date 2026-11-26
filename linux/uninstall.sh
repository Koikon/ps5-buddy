#!/usr/bin/env bash
# PS5 Buddy uninstall (Linux): removes the app, commands and menu entry.
# PS5Upload is removed only if the PS5 Buddy installer downloaded it (--keep-ps5upload keeps it).
set -uo pipefail
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ps5buddy"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ps5buddy"
keep_up=0; [ "${1:-}" = "--keep-ps5upload" ] && keep_up=1

for n in ps5-buddy ps5u-buddy; do
  t="$BIN_DIR/$n"
  [ -L "$t" ] && [[ "$(readlink -f "$t")" == "$APP_DIR"/* ]] && rm -f "$t"
done
rm -f "$APPS_DIR/ps5-buddy.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
if [ -f "$APP_DIR/previous-links" ]; then
  echo "Links PS5 Buddy replaced at install (not restored):"; sed 's/^/  /' "$APP_DIR/previous-links"
fi
if [ -f "$APP_DIR/.installed-ps5upload" ] && [ "$keep_up" = 0 ]; then
  rm -rf "$APP_DIR"
  echo "PS5 Buddy and the PS5Upload it installed are removed."
elif [ -f "$APP_DIR/.installed-ps5upload" ]; then
  mkdir -p "$HOME/Applications" && mv "$APP_DIR/PS5Upload.AppImage" "$HOME/Applications/PS5Upload.AppImage"
  rm -rf "$APP_DIR"
  echo "PS5 Buddy removed. PS5Upload kept at ~/Applications/PS5Upload.AppImage."
else
  rm -rf "$APP_DIR"
  echo "PS5 Buddy removed. PS5Upload was already on this PC, so it stays."
fi
rm -f "$CONF_DIR/linux.conf"
echo "Your saved PS5 / upload settings stay in $CONF_DIR (delete it to forget them)."

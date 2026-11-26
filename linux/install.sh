#!/usr/bin/env bash
# PS5 Buddy 2 installer for Linux (no root needed, installs for this user only).
# Installs PS5Upload (Tailscale is built in) + the PS5 Buddy app, menu entry and commands.
#
#   ./install.sh                 from an unpacked PS5-Buddy-Linux.tar.gz
#   curl -fsSL https://github.com/Koikon/ps5-buddy/releases/latest/download/install-linux.sh | bash
#
# Options: --no-launch (don't open PS5 Buddy at the end), --reinstall-ps5upload
set -euo pipefail

REPO="Koikon/ps5-buddy"
UP_REPO="phantomptr/ps5upload"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ps5buddy"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ps5buddy"
CONF="$CONF_DIR/linux.conf"

launch=1; reinstall_up=0
for a in "$@"; do case "$a" in
  --no-launch) launch=0 ;;
  --reinstall-ps5upload) reinstall_up=1 ;;
  -h|--help) sed -n 2,9p "$0"; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

c_step=$'\e[36m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_end=$'\e[0m'
[ -t 1 ] || { c_step=; c_ok=; c_warn=; c_end=; }
step() { printf '\n%s==> %s%s\n' "$c_step" "$1" "$c_end"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$1" "$c_end"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$1" "$c_end"; }
die()  { printf '\n%sERROR: %s%s\n' "$c_warn" "$1" "$c_end" >&2; exit 1; }

echo "========================================"
echo "  PS5 Buddy 2 - PS5Upload + Tailscale   "
echo "========================================"

# ---------- 0. needs ----------
for c in python3 curl sha256sum; do command -v "$c" >/dev/null || die "'$c' is missing - install it with your package manager and run this again."; done
case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported CPU $(uname -m) - PS5Upload ships Linux builds for x64 and arm64 only." ;;
esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
gh_json() { curl -fsSL -H 'User-Agent: ps5-buddy' "https://api.github.com/repos/$1/releases/latest"; }

# ---------- 1. PS5 Buddy files (next to this script, or from the latest release) ----------
src=""
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/ps5u_buddy.py" ] && [ -f "$here/ps5-buddy" ]; then
  src="$here"
elif [ -n "$here" ] && [ -f "$here/../ps5u_buddy.py" ] && [ -f "$here/ps5-buddy" ]; then
  # run from a checkout of the repo (linux/install.sh)
  src="$work/repo"; mkdir -p "$src"
  cp "$here/ps5-buddy" "$here/ps5_buddy_gui.py" "$here/uninstall.sh" "$here/install.sh" "$here/../ps5u_buddy.py" "$src/"
  v=$(sed -n "s/^\$Version = '\([0-9.]*\)'.*/\1/p" "$here/../windows/setup/gui.ps1" 2>/dev/null | head -1)
  [ -n "$v" ] && echo "$v" > "$src/VERSION"
else
  step "Downloading PS5 Buddy (latest release)"
  base="https://github.com/$REPO/releases/latest/download"
  curl -fsSL "$base/PS5-Buddy-Linux.tar.gz" -o "$work/PS5-Buddy-Linux.tar.gz" || die "download failed: $base/PS5-Buddy-Linux.tar.gz"
  curl -fsSL "$base/PS5-Buddy-Linux.tar.gz.sha256" -o "$work/PS5-Buddy-Linux.tar.gz.sha256" || die "no .sha256 file in the release - refusing to install an unverified download."
  (cd "$work" && sha256sum -c --quiet PS5-Buddy-Linux.tar.gz.sha256) || die "checksum mismatch - the download is damaged, try again."
  mkdir "$work/pkg"; tar -xzf "$work/PS5-Buddy-Linux.tar.gz" -C "$work/pkg"
  src="$work/pkg/PS5 Buddy"
  [ -f "$src/ps5u_buddy.py" ] || die "release archive is missing files."
  ok "Verified $(cut -d' ' -f1 "$work/PS5-Buddy-Linux.tar.gz.sha256" | cut -c1-16)..."
fi

# ---------- 2. PS5Upload ----------
step "Installing PS5Upload (with built-in Tailscale)"
find_ps5upload() {
  local p
  if [ -f "$CONF" ]; then p=$(sed -n 's/^PS5UPLOAD=//p' "$CONF" | head -1); [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return; }; fi
  for p in "$APP_DIR/PS5Upload.AppImage" /usr/bin/ps5upload-desktop /usr/bin/ps5upload /opt/PS5Upload/ps5upload-desktop; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  # AppImage registered by PS5Upload itself (its ps5upload:// link handler)
  for d in "$APPS_DIR"/ps5upload*.desktop /usr/share/applications/ps5upload*.desktop; do
    [ -f "$d" ] || continue
    p=$(sed -n 's/^Exec=//p' "$d" | head -1 | sed -E 's/ %[uUfF].*$//; s/^"//; s/"$//')
    [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return; }
  done
  for p in "$HOME"/Applications/PS5Upload*.AppImage "$HOME"/Downloads/PS5Upload*linux-$arch.AppImage; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
}
up=""
[ "$reinstall_up" = 1 ] || up=$(find_ps5upload || true)
if [ -n "$up" ]; then
  ok "Already installed: $up"
else
  gh_json "$UP_REPO" > "$work/up.json" || die "can't reach GitHub to download PS5Upload."
  read -r tag name url digest < <(python3 -I - "$work/up.json" "$arch" <<'EOF'
import json, sys, re
r = json.load(open(sys.argv[1])); arch = sys.argv[2]
for a in r.get("assets", []):
    if re.search(rf"linux-{arch}\.AppImage$", a["name"]):
        print(r["tag_name"], a["name"], a["browser_download_url"], (a.get("digest") or "-").replace("sha256:", "")); break
EOF
)
  [ -n "${url:-}" ] || die "no Linux $arch AppImage in PS5Upload's latest release - get it from github.com/$UP_REPO/releases."
  echo "    Downloading $name ($tag)"
  mkdir -p "$APP_DIR"
  curl -fL --progress-bar "$url" -o "$work/PS5Upload.AppImage" || die "PS5Upload download failed."
  if [ "$digest" != "-" ]; then
    echo "$digest  $work/PS5Upload.AppImage" | sha256sum -c --quiet - || die "PS5Upload checksum mismatch - try again."
    ok "Checksum OK"
  else
    warn "GitHub gave no checksum for this file - installed unverified."
  fi
  install -m 755 "$work/PS5Upload.AppImage" "$APP_DIR/PS5Upload.AppImage"
  up="$APP_DIR/PS5Upload.AppImage"
  echo "INSTALLED_PS5UPLOAD=1" > "$APP_DIR/.installed-ps5upload"
  ok "PS5Upload installed: $up"
fi
# AppImages need FUSE 2; without it run them self-extracting
libs=$(ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null || true)
if [[ "$up" == *.AppImage ]] && [[ "$libs" != *libfuse.so.2* ]]; then
  warn "libfuse2 not found - PS5Upload will run in extract mode (slower start). Installing fuse2 fixes that."
  extract=1
else
  extract=0
fi

# ---------- 3. PS5 Buddy app ----------
step "Installing PS5 Buddy"
mkdir -p "$APP_DIR" "$BIN_DIR" "$APPS_DIR" "$CONF_DIR"
install -m 755 "$src/ps5u_buddy.py" "$APP_DIR/ps5u_buddy.py"
install -m 755 "$src/ps5-buddy"     "$APP_DIR/ps5-buddy"
install -m 755 "$src/uninstall.sh"  "$APP_DIR/uninstall.sh"
[ -f "$src/ps5_buddy_gui.py" ] && install -m 755 "$src/ps5_buddy_gui.py" "$APP_DIR/ps5_buddy_gui.py"
[ -f "$src/install.sh" ] && install -m 755 "$src/install.sh" "$APP_DIR/install.sh"
[ -f "$src/VERSION" ] && install -m 644 "$src/VERSION" "$APP_DIR/VERSION"
for n in ps5-buddy ps5u-buddy; do
  t="$BIN_DIR/$n"
  if [ -L "$t" ] && [[ "$(readlink -f "$t")" != "$APP_DIR"/* ]]; then
    warn "$t pointed at $(readlink "$t") - kept a note in $APP_DIR/previous-links"
    echo "$t -> $(readlink "$t")" >> "$APP_DIR/previous-links"
  fi
done
ln -sfn "$APP_DIR/ps5-buddy"     "$BIN_DIR/ps5-buddy"
ln -sfn "$APP_DIR/ps5u_buddy.py" "$BIN_DIR/ps5u-buddy"
# keep saved settings, refresh the PS5Upload path
{ grep -v -e '^PS5UPLOAD=' -e '^EXTRACT=' "$CONF" 2>/dev/null || true
  echo "PS5UPLOAD=$up"; echo "EXTRACT=$extract"; } > "$CONF.new" && mv "$CONF.new" "$CONF"

cat > "$APPS_DIR/ps5-buddy.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PS5 Buddy
Comment=Low-lag PS5Upload Play over Tailscale
Exec="$APP_DIR/ps5-buddy"
Icon=input-gaming
StartupWMClass=io.github.koikon.PS5Buddy
Terminal=false
Categories=Game;Network;
Keywords=PS5;Remote Play;Tailscale;PS5Upload;
EOF
if python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw; assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5)' 2>/dev/null; then
  ok "Window app ready (GTK4 + libadwaita)."
else
  warn "No GTK4/libadwaita 1.5+ for Python - PS5 Buddy opens as a terminal menu instead."
  warn "For the window app install: Arch python-gobject libadwaita | Debian/Ubuntu python3-gi gir1.2-adw-1 | Fedora python3-gobject libadwaita"
fi
command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
ok "Commands: ps5-buddy (menu), ps5u-buddy (CLI). App launcher entry: PS5 Buddy."
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR isn't on your PATH - add it, or open PS5 Buddy from the app launcher." ;; esac

echo
printf '%sAll set!%s Uninstall any time with: %s/uninstall.sh\n' "$c_ok" "$c_end" "$APP_DIR"
if [ "$launch" = 1 ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  echo "Opening PS5 Buddy (it starts PS5Upload too)..."
  if [ -t 0 ] && [ -t 1 ]; then exec "$APP_DIR/ps5-buddy"; else (setsid "$APP_DIR/ps5-buddy" >/dev/null 2>&1 &); fi
fi

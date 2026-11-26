#!/usr/bin/env bash
# Build dist/PS5-Buddy-Windows.zip and dist/PS5-Buddy-Linux.tar.gz + SHA-256 files
# (the updaters refuse a download without one), plus dist/install-linux.sh for curl | bash.
set -euo pipefail
cd "$(dirname "$0")"
st=$(mktemp -d); trap 'rm -rf "$st"' EXIT
mkdir -p "$st/PS5 Buddy" dist
cp -r windows/. "$st/PS5 Buddy/"
find "$st" -type f \( -name '*.bat' -o -name '*.ps1' -o -name '*.txt' \) -exec unix2dos -q {} +
rm -f dist/PS5-Buddy-Windows.zip dist/PS5-Buddy-Windows.zip.sha256
(cd "$st" && zip -qr - "PS5 Buddy") > dist/PS5-Buddy-Windows.zip
(cd dist && sha256sum PS5-Buddy-Windows.zip > PS5-Buddy-Windows.zip.sha256)
echo "built dist/PS5-Buddy-Windows.zip  sha256 $(cut -d' ' -f1 dist/PS5-Buddy-Windows.zip.sha256)"

# ---- Linux ----
ver=$(sed -n "s/^\$Version = '\([0-9.]*\)'.*/\1/p" windows/setup/gui.ps1 | head -1)
ls_=$(mktemp -d); trap 'rm -rf "$st" "$ls_"' EXIT
mkdir -p "$ls_/PS5 Buddy"
cp linux/install.sh linux/uninstall.sh linux/ps5-buddy linux/ps5_buddy_gui.py ps5u_buddy.py "$ls_/PS5 Buddy/"
echo "$ver" > "$ls_/PS5 Buddy/VERSION"
chmod 755 "$ls_/PS5 Buddy/"{install.sh,uninstall.sh,ps5-buddy,ps5_buddy_gui.py,ps5u_buddy.py}
rm -f dist/PS5-Buddy-Linux.tar.gz dist/PS5-Buddy-Linux.tar.gz.sha256 dist/install-linux.sh
tar -C "$ls_" --owner=0 --group=0 -czf dist/PS5-Buddy-Linux.tar.gz "PS5 Buddy"
(cd dist && sha256sum PS5-Buddy-Linux.tar.gz > PS5-Buddy-Linux.tar.gz.sha256)
install -m 755 linux/install.sh dist/install-linux.sh
echo "built dist/PS5-Buddy-Linux.tar.gz  sha256 $(cut -d' ' -f1 dist/PS5-Buddy-Linux.tar.gz.sha256)  (v$ver)"

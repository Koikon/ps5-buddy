#!/usr/bin/env bash
# Publish an update friends get automatically (PS5 Buddy asks them on next launch).
#   ./release.sh 2.1.1 "What changed, one line per change"
set -euo pipefail
cd "$(dirname "$0")"
ver="${1:?usage: ./release.sh <version> \"notes\"}"; notes="${2:-Bug fixes and improvements.}"
in_gui=$(grep -oP "^\\\$Version = '\K[\d.]+" windows/setup/gui.ps1)
if [ "$in_gui" != "$ver" ]; then
  sed -i "s/^\$Version = '[0-9.]*'/\$Version = '$ver'/" windows/setup/gui.ps1
  echo "set \$Version in gui.ps1: $in_gui -> $ver"
fi
[ -z "$(git status --porcelain)" ] || { git add -A; git commit -qm "PS5 Buddy $ver" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; }
git push -q
./build-release.sh
gh release create "v$ver" dist/PS5-Buddy-Windows.zip dist/PS5-Buddy-Windows.zip.sha256 \
  dist/PS5-Buddy-Linux.tar.gz dist/PS5-Buddy-Linux.tar.gz.sha256 dist/install-linux.sh \
  --title "PS5 Buddy $ver" --notes "$notes"
echo "released v$ver - friends get the update prompt next time they open PS5 Buddy"

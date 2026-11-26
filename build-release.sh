#!/usr/bin/env bash
# Build dist/PS5-Buddy-Windows.zip + its SHA-256 (the updater refuses a zip without it).
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

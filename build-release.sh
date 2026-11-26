#!/usr/bin/env bash
# Build dist/PS5-Buddy-Windows.zip (the one-click Windows package).
set -euo pipefail
cd "$(dirname "$0")"
st=$(mktemp -d); trap 'rm -rf "$st"' EXIT
mkdir -p "$st/PS5 Buddy" dist
cp -r windows/. "$st/PS5 Buddy/"
find "$st" -type f \( -name '*.bat' -o -name '*.ps1' -o -name '*.txt' \) -exec unix2dos -q {} +
rm -f dist/PS5-Buddy-Windows.zip
(cd "$st" && zip -qr - "PS5 Buddy") > dist/PS5-Buddy-Windows.zip
echo "built dist/PS5-Buddy-Windows.zip"

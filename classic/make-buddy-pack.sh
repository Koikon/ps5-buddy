#!/usr/bin/env bash
# Build the friend's one-click Windows pack.
#   ./make-buddy-pack.sh --ps5 172.19.168.X --host <your-pc-tailscale-name> [--authkey tskey-auth-...]
# Output: dist/PS5-Buddy-Windows.zip  (send it privately if it contains an auth key)
set -euo pipefail
cd "$(dirname "$0")"
PS5="" HOSTNODE="" KEY="" UP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ps5) PS5="$2"; shift 2;;
    --host) HOSTNODE="$2"; shift 2;;
    --authkey) KEY="$2"; shift 2;;
    --upload) UP="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 1;;
  esac
done
[ -n "$PS5" ] || { echo "need --ps5 <PS5 LAN IP>"; exit 1; }
[ -n "$HOSTNODE" ] || HOSTNODE="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["HostName"])' 2>/dev/null || hostname)"

# Host upload = the PS5 stream's ceiling. Measure it unless given (--upload <Mbps>).
if [ -z "$UP" ]; then
  echo "Measuring your upload (2 x 25 MB to speed.cloudflare.com)..."
  UP=$(for i in 1 2; do head -c 25000000 /dev/zero | curl -s -o /dev/null -w '%{speed_upload}\n' --data-binary @- https://speed.cloudflare.com/__up; done \
       | sort -n | head -1 | awk '{printf "%d", $1*8/1000000}')
fi
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/PS5 Buddy" dist
cp -r windows/. "$stage/PS5 Buddy/"
cat > "$stage/PS5 Buddy/setup/buddy.ini" <<EOF
; PS5 Buddy settings (made by the host on $(date +%F))
PS5_IP=$PS5
HOST_NODE=$HOSTNODE
AUTHKEY=$KEY
UPLOAD_MBPS=$UP
EOF
find "$stage" -type f \( -name '*.bat' -o -name '*.ps1' -o -name '*.ini' -o -name '*.txt' \) -exec unix2dos -q {} +
rm -f dist/PS5-Buddy-Windows.zip
(cd "$stage" && zip -qr - "PS5 Buddy") > dist/PS5-Buddy-Windows.zip
echo "Built dist/PS5-Buddy-Windows.zip  (PS5=$PS5 host=$HOSTNODE upload=${UP}Mbps key=$([ -n "$KEY" ] && echo yes || echo no))"
[ -n "$KEY" ] && echo "!! Contains a Tailscale auth key: send it privately (DM, not a public channel). Use a ONE-OFF, expiring, tag:buddy key."
exit 0

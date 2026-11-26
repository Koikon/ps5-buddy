#!/usr/bin/env python3
"""ps5buddy - host side of PS5 Buddy (Linux).

The PS5 can't run Tailscale, so this PC joins Tailscale *for* it and routes
only the PS5's address to the friend. The stream still comes from the PS5 and
leaves on the house upload; this program makes that upload path fast.

  1. CONNECTION   custom Tailscale: PS5 published as a /32 subnet route,
                  pinned UDP port for direct links, firewall opened only for
                  PS5 Remote Play ports.
  2. ACCELERATION CAKE queue on the uplink (no bufferbloat), Tailscale's
                  packets marked top priority (DSCP EF), UDP GRO forwarding,
                  tailscaled CPU priority.
  3. ALGORITHM    `watch`: measures ping/jitter to the friend and how busy the
                  upload is, and steers CAKE's speed limit up/down in real time
                  (latency-based autorate) + tells you the friend's best tier.

Commands:
  ps5buddy find                       find the PS5 on the LAN
  sudo ps5buddy setup --ps5 IP        one-time setup (connection + acceleration)
  ps5buddy status                     show everything
  sudo ps5buddy watch [--friend NODE] live algorithm (Ctrl+C to stop)
  ps5buddy pack [--authkey KEY]       build the friend's Windows zip
  ps5buddy invite [--authkey KEY]     invite code to paste into the friend's app
  sudo ps5buddy off                   remove acceleration (keeps Tailscale)
"""
import argparse, json, os, re, shutil, socket, statistics, subprocess, sys, time

CONF = "/etc/ps5buddy.json"
HERE = os.path.dirname(os.path.realpath(__file__))
TS_PORT = 41641
NFT_TABLE = "ps5buddy"
RP_PORTS = "9295:9304"           # PS5 Remote Play (tcp+udp)

# Same tiers the friend's Windows app uses: (name, kbps, max rtt, max jitter, max loss)
TIERS = [("ULTRA 1080p60", 15000, 20, 4, 0), ("HIGH 1080p60", 10000, 35, 7, 1),
         ("SMOOTH 720p60", 6000, 60, 12, 2), ("SAFE 540p60", 3000, 9999, 9999, 100)]

# ---------------------------------------------------------------- helpers
def sh(cmd, check=False, quiet=True):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"failed: {cmd}\n{r.stderr.strip()}")
    return r.stdout.strip() if quiet else r

def need_root():
    if os.geteuid() != 0:
        sys.exit("run this with sudo:  sudo " + " ".join(sys.argv))

def load():
    try:
        return json.load(open(CONF))
    except Exception:
        return {}

def save(c):
    json.dump(c, open(CONF, "w"), indent=2)
    os.chmod(CONF, 0o644)

def ts_status():
    try:
        return json.loads(sh(["tailscale", "status", "--json"]))
    except Exception:
        return None

def uplink_dev():
    """The interface the router actually sits behind (a br0 port, or the route dev)."""
    gw = sh("ip -4 route show default | awk 'NR==1{print $3}'")
    dev = sh("ip -4 route show default | awk 'NR==1{print $5}'")
    mac = sh(f"ip neigh show {gw} | awk '{{print $5}}'") if gw else ""
    if mac and os.path.isdir(f"/sys/class/net/{dev}/bridge"):
        m = re.search(r"dev (\S+) master", sh(f"bridge fdb show br {dev} | grep -i {mac}"))
        if m:
            return m.group(1)
    return dev

def measure_upload_mbps():
    print("measuring upload (2 x 25 MB to speed.cloudflare.com)...")
    speeds = []
    for _ in range(2):
        out = sh("head -c 25000000 /dev/zero | curl -s -o /dev/null -w '%{speed_upload}' "
                 "--data-binary @- https://speed.cloudflare.com/__up")
        try: speeds.append(float(out) * 8 / 1e6)
        except ValueError: pass
    return round(min(speeds), 1) if speeds else 0

def tx_bytes(dev):
    try: return int(open(f"/sys/class/net/{dev}/statistics/tx_bytes").read())
    except Exception: return 0

def ts_ping(node):
    """-> (rtt_ms or None, 'direct ip:port' / 'relay xyz')"""
    out = sh(["tailscale", "ping", "--c", "1", "--timeout", "2s", node])
    m = re.search(r"via (DERP\(([^)]+)\)|\S+) in ([\d.]+)ms", out)
    if not m:
        return None, "unreachable"
    via = f"relay {m.group(2)}" if m.group(2) else f"direct {m.group(1)}"
    return float(m.group(3)), via

def pick_tier(rtt, jit, loss, direct, cap_kbps):
    for name, kbps, r, j, l in TIERS:
        if rtt <= r and jit <= j and loss <= l and kbps <= cap_kbps:
            if not direct and name.startswith("ULTRA"):
                continue
            return name, kbps
    return TIERS[-1][0], TIERS[-1][1]

# ---------------------------------------------------------------- find
def find_ps5(timeout=3):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(timeout)
    s.sendto(b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n", ("255.255.255.255", 9302))
    found = []
    try:
        while True:
            d, a = s.recvfrom(2048)
            t = d.decode(errors="replace")
            name = re.search(r"host-name:(.*)", t)
            state = "awake" if " 200 " in t.splitlines()[0] else "rest mode"
            found.append((a[0], name.group(1).strip() if name else "PlayStation", state))
    except socket.timeout:
        pass
    return found

def cmd_find(a):
    found = find_ps5()
    if not found:
        print("no PS5 answered. Turn it on, enable Settings > System > Remote Play, and in\n"
              "Power Saving > Features in Rest Mode turn on 'Stay connected to the internet'.")
        return 1
    for ip, name, state in found:
        print(f"{ip:16} {name}  ({state})")

# ---------------------------------------------------------------- setup
def cmd_setup(a):
    need_root()
    c = load()
    ps5 = a.ps5 or c.get("ps5_ip")
    if not ps5:
        f = find_ps5()
        if not f: sys.exit("PS5 not found - pass --ps5 <ip> (see `ps5buddy find`)")
        ps5 = f[0][0]
    if not shutil.which("tailscale"):
        sys.exit("install Tailscale first:  sudo pacman -S tailscale")
    up = a.upload or c.get("upload_mbps") or measure_upload_mbps()
    dev = a.uplink or uplink_dev()
    c.update(ps5_ip=ps5, upload_mbps=up, uplink=dev)

    print(f"[1/3] CONNECTION  PS5 {ps5} -> Tailscale route")
    # forwarding, persistent
    open("/etc/sysctl.d/90-ps5buddy.conf", "w").write(
        "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n")
    sh("sysctl -q -p /etc/sysctl.d/90-ps5buddy.conf")
    # pin the WireGuard port so a router port-forward / DSCP rule can target it
    d = open("/etc/default/tailscaled").read() if os.path.exists("/etc/default/tailscaled") else 'FLAGS=""\n'
    d = re.sub(r'(?m)^PORT=.*\n?', '', d)
    open("/etc/default/tailscaled", "w").write(f'PORT="{TS_PORT}"\n' + d)
    # tailscaled CPU priority (encrypting the video stream)
    os.makedirs("/etc/systemd/system/tailscaled.service.d", exist_ok=True)
    open("/etc/systemd/system/tailscaled.service.d/ps5buddy.conf", "w").write(
        "[Service]\nNice=-10\n")
    sh("systemctl daemon-reload")
    sh("systemctl enable tailscaled"); sh("systemctl restart tailscaled"); time.sleep(3)
    st = ts_status()
    if not st or st.get("BackendState") != "Running":
        print("      logging in to Tailscale (a link will appear):")
        subprocess.run(["tailscale", "up", f"--advertise-routes={ps5}/32"])
    else:
        sh(["tailscale", "set", f"--advertise-routes={ps5}/32"], check=True)
    # firewall: forward only Remote Play ports from tailscale0 to the PS5
    if sh("systemctl is-active ufw") == "active":
        for proto in ("tcp", "udp"):
            sh(f"ufw route allow in on tailscale0 to {ps5} port {RP_PORTS} proto {proto} comment ps5buddy")
        sh(f"ufw allow {TS_PORT}/udp comment 'ps5buddy tailscale direct'")
    print("      route advertised. Approve it once: admin console > Machines > this PC >\n"
          "      Edit route settings > tick the PS5 route (or use autoApprovers).")

    print(f"[2/3] ACCELERATION on uplink {dev} ({up} Mbps measured)")
    accel_on(c)
    print("[3/3] ALGORITHM   run `sudo ps5buddy watch` while your friend plays")
    save(c)
    print(f"\ndone. config in {CONF}")

def accel_on(c):
    dev, up = c["uplink"], float(c["upload_mbps"])
    bw = c.get("cake_mbps") or round(up * 0.9, 1)
    # CAKE: fair, low-latency queue; diffserv4 gives EF traffic the 'voice' tin
    sh(f"tc qdisc replace dev {dev} root cake bandwidth {bw}mbit diffserv4 nat ack-filter", check=True)
    c["cake_mbps"] = bw
    # mark Tailscale's packets (= the PS5 stream to the friend) as EF / top priority
    sh(f"nft delete table inet {NFT_TABLE}")
    rules = f"""table inet {NFT_TABLE} {{
      chain post {{ type filter hook postrouting priority mangle; policy accept;
        udp sport {TS_PORT} ip dscp set ef
        udp sport {TS_PORT} ip6 dscp set ef
        oifname "tailscale0" ip dscp set ef
      }}
    }}"""
    r = subprocess.run(["nft", "-f", "-"], input=rules, text=True, capture_output=True)
    if r.returncode: print("      nft:", r.stderr.strip())
    # UDP GRO forwarding: Tailscale's recommended speedup for subnet routers
    for d in {dev, sh("ip -4 route show default | awk 'NR==1{print $5}'")}:
        sh(f"ethtool -K {d} rx-udp-gro-forwarding on rx-gro-list off")
    # keep it across reboots
    unit = f"""[Unit]
Description=PS5 Buddy acceleration
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={sys.executable} {os.path.realpath(__file__)} _accel
ExecStop={sys.executable} {os.path.realpath(__file__)} _unaccel
[Install]
WantedBy=multi-user.target
"""
    open("/etc/systemd/system/ps5buddy.service", "w").write(unit)
    sh("systemctl daemon-reload"); sh("systemctl enable ps5buddy.service")
    print(f"      CAKE {bw} Mbps + stream priority (EF) + UDP GRO forwarding: on")

def cmd_accel(a):
    need_root(); c = load()
    if c.get("uplink"): accel_on(c); save(c)

def cmd_off(a):
    need_root(); c = load()
    if c.get("uplink"): sh(f"tc qdisc del dev {c['uplink']} root")
    sh(f"nft delete table inet {NFT_TABLE}")
    if a.__dict__.get("cmd") == "off":
        sh("systemctl disable ps5buddy.service")
    print("acceleration off (Tailscale route left in place)")

# ---------------------------------------------------------------- status
def cmd_status(a):
    c = load()
    st = ts_status()
    print("PS5 Buddy (host)")
    print(f"  PS5        : {c.get('ps5_ip', '? (run setup)')}")
    print(f"  Tailscale  : {st.get('BackendState') if st else 'not installed/running'}"
          + (f"  ({st['Self']['HostName']} {st['Self']['TailscaleIPs'][0]})" if st and st.get('Self') else ""))
    if st and st.get("Self"):
        routes = st["Self"].get("PrimaryRoutes") or []
        print(f"  PS5 route  : {'live' if any(c.get('ps5_ip','-') in r for r in routes) else 'not approved yet'}")
    q = sh(f"tc qdisc show dev {c.get('uplink','lo')} root")
    m = re.search(r"bandwidth (\S+)", q)
    cake = m.group(1) if "cake" in q and m else "off"
    print(f"  Upload     : {c.get('upload_mbps','?')} Mbps   CAKE: {cake}")
    print(f"  Priority   : {'on' if NFT_TABLE in sh('nft list tables 2>/dev/null') else 'off'}")
    if st:
        for p in (st.get("Peer") or {}).values():
            if p.get("Online"):
                path = "direct" if p.get("CurAddr") else f"relay {p.get('Relay','?')}"
                print(f"  Peer online: {p['HostName']:20} {path}")

# ---------------------------------------------------------------- watch (algorithm)
def cmd_watch(a):
    """Latency-driven autorate + tier advice.

    Each tick (2 s):
      rtt   = Tailscale ping to the friend (same path the video takes)
      base  = lowest rtt seen in the last ~2 min (the line's true speed)
      bloat = rtt - base   (queueing delay = what causes lag spikes)
      load  = how much of CAKE's limit the uplink is actually using
    Control:
      bloat > 15 ms           -> cut CAKE limit 10%  (stop the queue from filling)
      bloat < 5 ms, load >80% -> raise limit 3%      (give the stream room back)
      limit stays in [40%, 95%] of measured upload
    Then picks the friend's best stream tier for the current line and limit.
    """
    c = load()
    if not c: sys.exit("run `sudo ps5buddy setup` first")
    root = os.geteuid() == 0
    friend = a.friend or c.get("friend_node")
    st = ts_status()
    if not friend and st:
        online = [p["HostName"] for p in (st.get("Peer") or {}).values()
                  if p.get("Online") and "buddy" in p["HostName"].lower()]
        friend = online[0] if online else None
    if not friend: sys.exit("friend not online - pass --friend <tailscale name>")
    if root and a.friend: c["friend_node"] = a.friend; save(c)

    up = float(c["upload_mbps"]); dev = c["uplink"]
    bw = float(c.get("cake_mbps") or up * 0.9)
    lo, hi = up * 0.40, up * 0.95
    hist, last_tx, last_t, changed = [], tx_bytes(dev), time.time(), 0
    tier_now, tier_cnt = None, 0
    print(f"watching {friend}  (upload {up} Mbps, CAKE {bw:.1f})  Ctrl+C to stop"
          + ("" if root else "  [read-only: run with sudo to auto-tune]"))
    print(f"{'time':8} {'ping':>6} {'jit':>5} {'bloat':>6} {'used':>8} {'limit':>7}  path / friend tier")
    try:
        while True:
            rtt, via = ts_ping(friend)
            now = time.time(); tx = tx_bytes(dev)
            used = (tx - last_tx) * 8 / 1e6 / max(now - last_t, 0.1)
            last_tx, last_t = tx, now
            hist.append(rtt); hist = hist[-60:]
            good = [h for h in hist if h is not None]
            if rtt is None or not good:
                print(f"{time.strftime('%H:%M:%S')}   ----  friend unreachable ({via})"); time.sleep(2); continue
            base = min(good)
            bloat = rtt - base
            jit = statistics.mean(abs(x - y) for x, y in zip(good[1:], good[:-1])) if len(good) > 1 else 0
            loss = 100 * hist.count(None) / len(hist)
            new = bw
            if bloat > 15: new = max(lo, bw * 0.90)
            elif bloat < 5 and used > 0.8 * bw: new = min(hi, bw * 1.03)
            if root and abs(new - bw) > 0.05 and now - changed > 4:
                sh(f"tc qdisc change dev {dev} root cake bandwidth {new:.1f}mbit")
                bw, changed = new, now
                c["cake_mbps"] = round(bw, 1); save(c)
            # stream may use 60% of the shaped limit, rest for the house
            tier, kbps = pick_tier(rtt, jit, loss, via.startswith("direct"), bw * 1000 * 0.6)
            note = ""
            if tier != tier_now:
                tier_cnt += 1
                if tier_cnt >= 2 or tier_now is None:
                    note = "  <- tell friend" if tier_now else ""
                    tier_now, tier_cnt = tier, 0
            else:
                tier_cnt = 0
            print(f"{time.strftime('%H:%M:%S')} {rtt:5.1f}ms {jit:4.1f} {bloat:5.1f} {used:6.1f}Mb {bw:6.1f}  "
                  f"{via} / {tier_now} {kbps}k{note}")
            time.sleep(2)
    except KeyboardInterrupt:
        print("\nstopped.")

# ---------------------------------------------------------------- pack
def cmd_pack(a):
    c = load()
    if not c.get("ps5_ip"): sys.exit("run `sudo ps5buddy setup` first")
    st = ts_status()
    host = st["Self"]["HostName"] if st and st.get("Self") else socket.gethostname()
    args = [os.path.join(HERE, "make-buddy-pack.sh"), "--ps5", c["ps5_ip"], "--host", host,
            "--upload", str(int(float(c["upload_mbps"])))]
    if a.authkey: args += ["--authkey", a.authkey]
    subprocess.run(args, check=True)

def cmd_invite(a):
    import base64
    c = load()
    if not c.get("ps5_ip"): sys.exit("run `sudo ps5buddy setup` first")
    st = ts_status()
    host = st["Self"]["HostName"] if st and st.get("Self") else socket.gethostname()
    j = json.dumps({"ps5": c["ps5_ip"], "host": host, "up": float(c["upload_mbps"]), "key": a.authkey or ""},
                   separators=(",", ":"))
    print("PS5B1:" + base64.b64encode(j.encode()).decode())
    if a.authkey: print("(contains your auth key: send it privately)", file=sys.stderr)

# ---------------------------------------------------------------- main
def main():
    p = argparse.ArgumentParser(prog="ps5buddy", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("find").set_defaults(f=cmd_find)
    s = sp.add_parser("setup"); s.set_defaults(f=cmd_setup)
    s.add_argument("--ps5"); s.add_argument("--upload", type=float); s.add_argument("--uplink")
    sp.add_parser("status").set_defaults(f=cmd_status)
    w = sp.add_parser("watch"); w.set_defaults(f=cmd_watch); w.add_argument("--friend")
    k = sp.add_parser("pack"); k.set_defaults(f=cmd_pack); k.add_argument("--authkey")
    i = sp.add_parser("invite"); i.set_defaults(f=cmd_invite); i.add_argument("--authkey")
    sp.add_parser("off").set_defaults(f=cmd_off)
    sp.add_parser("_accel").set_defaults(f=cmd_accel)
    sp.add_parser("_unaccel").set_defaults(f=cmd_off)
    a = p.parse_args()
    sys.exit(a.f(a) or 0)

if __name__ == "__main__":
    main()

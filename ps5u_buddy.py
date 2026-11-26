#!/usr/bin/env python3
"""ps5u-buddy - PS5 Buddy for PS5Upload (jailbroken PS5 with PS5Upload's built-in Tailscale).

The PS5 itself is on Tailscale (PS5Upload helper), so the stream goes straight
from the PS5's upload to the player. This tool drives the local PS5Upload engine
(http://127.0.0.1:19113) to:

  check   connection report: Tailscale on/signed in, PS5 path (direct / relayed),
          latency, PS5 wired or Wi-Fi, what to fix
  play    measure the line, pick the best quality the line + the PS5's upload can
          hold, start PS5Upload Play at exactly that, then watch the stream and
          step down a tier if it keeps losing packets (adaptive quality)
  invite  print an invite code for the friend's PS5 Buddy (PS5 tailnet address +
          the house upload)

  ps5u-buddy check  [--ps5 ADDR]
  ps5u-buddy play   [--ps5 ADDR] [--upload MBPS] [--no-adapt]
  ps5u-buddy invite [--ps5 ADDR] [--upload MBPS]
  ps5u-buddy normal-invite [--ps5 ADDR] [--upload MBPS]
          ps5upload://console link for a friend with plain PS5Upload (no PS5 Buddy),
          plus the no-lag settings to set in their PS5Upload > Play > Settings
  ps5u-buddy tailscale-mode builtin|system
          builtin = PS5Upload's own Tailscale; system = the normal Tailscale app
"""
import argparse, base64, json, os, statistics, sys, time, urllib.request, urllib.error

ENGINE = os.environ.get("PS5UPLOAD_ENGINE", "http://127.0.0.1:19113")
CONF = os.path.expanduser("~/.config/ps5buddy/ps5u.json")

# name, width, height, fps, kbps, codec, max ping, max jitter
TIERS = [
    ("ULTRA",  1920, 1080, 60, 15000, "h265", 20, 4),
    ("HIGH",   1920, 1080, 60, 10000, "h265", 35, 7),
    ("SMOOTH", 1280,  720, 60,  6000, "h265", 60, 12),
    ("SAFE",   1280,  720, 30,  3000, "h264", 9e9, 9e9),
]
UPLOAD_SHARE = 0.6        # stream may use 60% of the house upload


# ---------------------------------------------------------------- engine API
def api(method, path, body=None, timeout=25):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ENGINE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}

def engine_up():
    s, _ = api("GET", "/api/tailnet", timeout=3)
    return s == 200

def load_conf():
    try: return json.load(open(CONF))
    except Exception: return {}

def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    json.dump(c, open(CONF, "w"), indent=2)

def pick_console(arg):
    """The PS5 to use: --ps5, saved, or the only one PS5Upload knows."""
    if arg: return arg
    c = load_conf()
    if c.get("ps5"): return c["ps5"]
    s, d = api("GET", "/api/consoles")
    items = d if isinstance(d, list) else d.get("consoles", []) if isinstance(d, dict) else []
    for it in items:
        a = it.get("addr") or it.get("host") or it.get("ip")
        if a: return a
    s, d = api("GET", "/api/tailnet")
    for k in d.get("consoles", []):
        return k.get("ip") or k.get("host")
    return None


# ---------------------------------------------------------------- the algorithm
def via(ps5):
    """-> (path 'lan'|'direct'|'relayed'|'system', latency ms or None)"""
    s, d = api("GET", f"/api/tailnet/via?addr={ps5}", timeout=5)
    ms = d.get("latency_ms", -1)
    return d.get("via", "?"), (ms if isinstance(ms, (int, float)) and ms >= 0 else None)

def measure(ps5, n=10, gap=0.5):
    """Sample Tailscale latency to the PS5 a few times -> dict."""
    samples, path = [], "?"
    for _ in range(n):
        path, ms = via(ps5)
        samples.append(ms)
        time.sleep(gap)
    good = [x for x in samples if x is not None]
    if not good:
        return {"path": path, "rtt": None, "jit": None, "n": 0}
    jit = statistics.mean(abs(a - b) for a, b in zip(good[1:], good[:-1])) if len(good) > 1 else 0.0
    return {"path": path, "rtt": round(statistics.median(good), 1), "jit": round(jit, 1), "n": len(good)}

def pick_tier(m, upload_mbps, below=None):
    """Best tier the line (ping/jitter/path) and the PS5's upload can hold.
    below: only tiers lower than this name (used when stepping down)."""
    cap = upload_mbps * 1000 * UPLOAD_SHARE if upload_mbps else 9e9
    start = 0
    if below:
        start = [t[0] for t in TIERS].index(below) + 1
        start = min(start, len(TIERS) - 1)
    for t in TIERS[start:]:
        name, w, h, fps, kbps, codec, max_rtt, max_jit = t
        if m["path"] == "lan":                       # at home: only the cap matters
            if kbps <= cap: return t
            continue
        rtt = m["rtt"] if m["rtt"] is not None else 50   # unknown latency: assume middling
        jit = m["jit"] if m["jit"] is not None else 8
        if m["path"] == "relayed" and name == "ULTRA":   # relays wobble: no top tier
            continue
        if rtt <= max_rtt and jit <= max_jit and kbps <= cap:
            return t
    return TIERS[-1]

def describe(t):
    return f"{t[0]}  {t[2]}p{t[3]}  {t[4]} kbps  {t[5].upper()}"


# ---------------------------------------------------------------- commands
# ---------------------------------------------------------------- normal PS5Upload invite
# PS5Upload's own "Invite a device" link (client/src/screens/Connection/consoles/model.ts):
# ps5upload://console?n=<name>&h=<home addr>&t=<tailscale addr>&k=<AVA1 key hex>. It only says
# how to reach the console; the console still asks before a new device gets in. Stream settings
# live in each PS5Upload app (Play > Settings), so they travel as text next to the link.
RP_BITRATES = [50000, 40000, 30000, 20000, 15000, 12000, 10000, 8000, 6000, 4500, 3000]

def low_lag_settings(upload_mbps):
    """The PS5Upload Play > Settings a friend should pick for the least lag on this host's line."""
    cap = upload_mbps * 1000 * UPLOAD_SHARE if upload_mbps else 10000
    kbps = next((b for b in RP_BITRATES if b <= min(cap, 10000)), 3000)  # 10 Mbps holds best over the internet
    hd = kbps >= 8000
    return {   # labels as PS5Upload shows them in Play > Settings
        "Low latency": "On (smallest sound buffer + shortest picture queue)",
        "Lower quality on a busy network": "On",
        "Picture": "1080p" if hd else "720p",
        "Frame rate": "60",
        "Bitrate": f"{kbps / 1000:g} Mbps",
        "Video format": "Auto",
        "Video decoding": "Auto",
    }

def normal_invite(ps5, upload_mbps):
    """-> (ps5upload://console link, message with the no-lag settings, tailnet ip or None)"""
    from urllib.parse import urlencode, quote
    s, ident = api("GET", f"/api/ava1/console?addr={quote(ps5, safe='')}", timeout=8)
    s, pt = api("GET", f"/api/ps5/tailnet?addr={quote(ps5, safe='')}", timeout=15)
    tip = pt.get("ip") or None
    q = {"n": (ident.get("name") or "PS5")[:64]}
    if not str(ps5).startswith("100."): q["h"] = ps5
    if tip: q["t"] = tip
    elif str(ps5).startswith("100."): q["t"] = ps5
    key = str(ident.get("key") or "").lower()
    if len(key) == 64: q["k"] = key
    link = "ps5upload://console?" + urlencode(q)
    lines = ["PS5 invite (open it, or paste it in PS5Upload > Connection > Add a PS5):", link, "",
             "No-lag settings for PS5Upload > Play > Settings:"]
    lines += [f"  {k}: {v}" for k, v in low_lag_settings(upload_mbps).items()]
    lines += ["", "Also: plug your PC into ethernet if you can, and turn on Tailscale in",
              "PS5Upload > Settings > Tailscale (or the Tailscale app) signed in to the tailnet I invite you to."]
    return link, "\n".join(lines), tip

def set_tailscale_mode(mode):
    """builtin: PS5Upload signs in as its own Tailscale device. system: it uses the normal
    Tailscale app on this computer (that app must be installed and signed in)."""
    if mode == "system":
        s, tn = api("GET", "/api/tailnet")
        if tn.get("enabled"):
            api("POST", "/api/tailnet", {"op": "disable"}, timeout=30)
        s, d = api("POST", "/api/tailnet", {"op": "system_choice", "choice": "system"}, timeout=30)
    else:
        s, d = api("POST", "/api/tailnet", {"op": "system_choice", "choice": "own"}, timeout=30)
    return s, d

def tailscale_mode(tn):
    """-> 'builtin' | 'system' as chosen (backend says what is in use now)."""
    if tn.get("backend") == "system" or (tn.get("system") or {}).get("choice") == "system":
        return "system"
    return "builtin"

def need_engine():
    if not engine_up():
        sys.exit(f"PS5Upload isn't running (no engine at {ENGINE}). Open the PS5Upload app first.")

def cmd_check(a):
    need_engine()
    s, tn = api("GET", "/api/tailnet")
    print("PS5 Buddy check (PS5Upload)")
    print(f"  Tailscale in PS5Upload : {'ON' if tn.get('enabled') else 'OFF'}, "
          f"{'signed in' if tn.get('signed_in') else 'not signed in'}, state {tn.get('state')}"
          + (f", this device {tn.get('ip')}" if tn.get("ip") else ""))
    fixes = []
    if not tn.get("enabled") or not tn.get("signed_in"):
        fixes.append("Turn on Tailscale: PS5Upload > Settings > Tailscale > sign in (or `ps5u-buddy tailscale-on`).")
    ps5 = pick_console(a.ps5)
    if not ps5:
        print("  PS5                    : none added in PS5Upload")
        fixes.append("Add the PS5: PS5Upload > Connection > Add a PS5 (scan home or Tailscale network).")
    else:
        path, ms = via(ps5)
        print(f"  PS5                    : {ps5}")
        print(f"  Path to PS5            : {path}" + (f", {ms:.0f} ms" if ms is not None else ""))
        if path == "relayed":
            fixes.append("Link is RELAYED (slower). On the host's router enable UPnP, or check that UDP isn't blocked.")
        s, lh = api("GET", f"/api/ps5/link-history?addr={ps5}&read_link=1", timeout=10)
        lk = lh.get("link")
        link = (lk.get("kind") if isinstance(lk, dict) else lk) or "unknown"
        print(f"  PS5 network            : {link}")
        if str(link).lower() == "wifi":
            fixes.append("PS5 is on Wi-Fi: an ethernet cable on the PS5 is the biggest lag fix.")
        drops = [e for e in lh.get("events", []) if e.get("kind") == "drop"]
        if drops:
            print(f"  Drops (last day)       : {len(drops)}")
    print("\n  " + ("\n  ".join("FIX: " + f for f in fixes) if fixes else "All good."))

def cmd_tailscale_on(a):
    need_engine()
    s, tn = api("GET", "/api/tailnet")
    if tailscale_mode(tn) == "system":
        sysd = tn.get("system") or {}
        print("Mode is the normal Tailscale app: " + (f"on, {sysd.get('ip')}" if sysd.get("detected")
              else "not running - install/sign in from https://tailscale.com/download"))
        return
    s, d = api("POST", "/api/tailnet", {"op": "enable", **({"authkey": a.authkey} if a.authkey else {})})
    print("enable:", s, d.get("error", "ok"))
    for _ in range(30):
        s, tn = api("GET", "/api/tailnet")
        if tn.get("login_url"):
            print("Sign in here:", tn["login_url"]); break
        if tn.get("state") == "running" or tn.get("ip"):
            print("Tailscale running:", tn.get("ip")); break
        time.sleep(1)

def cmd_play(a):
    need_engine()
    ps5 = pick_console(a.ps5)
    if not ps5: sys.exit("no PS5 in PS5Upload - add it first (ps5u-buddy check)")
    c = load_conf()
    up = a.upload or c.get("upload_mbps")
    print(f"Measuring the line to {ps5} ...")
    m = measure(ps5)
    t = pick_tier(m, up)
    print(f"  path {m['path']}, ping {m['rtt']} ms, jitter {m['jit']} ms, "
          f"house upload {up or '?'} Mbps")
    print(f"  -> starting PS5Upload Play at {describe(t)}")
    s, d = start(ps5, t)
    if not d.get("ok"):
        sys.exit(f"start failed ({s}): {d.get('error') or d.get('code') or d}")
    print(f"  playing (session {d.get('session')}). Open PS5Upload > Play to see it.")
    if a.no_adapt:
        return
    adapt(ps5, t, d.get("session"), m, up)

def start(ps5, t, wait=30):
    name, w, h, fps, kbps, codec, *_ = t
    body = {"host": ps5, "width": w, "height": h, "fps": fps, "bitrate_kbps": kbps,
            "codec": codec, "wait_s": wait, "keep_alive_s": 600}
    for attempt in range(1, 5):
        s, d = api("POST", "/api/ps5/rp/start", body, timeout=wait + 10)
        why = f"{d.get('code', '')} {d.get('error', '')}"
        if d.get("ok") or "busy" not in why or "busy_other" in why or "busy_user" in why:
            return s, d
        pause = min(30, int(d.get("retry_s") or 7) + 1)
        print(f"  PS5 still releasing the last stream - retrying in {pause} s ({attempt}/4)")
        time.sleep(pause)
    return s, d

def adapt(ps5, t, session, m, up):
    """Watch the running stream. If it keeps losing packets (2 windows of 10 s in a
    row), restart one tier lower. Never raises by itself (a restart interrupts play);
    says when the line could hold more."""
    print("Watching the stream (Ctrl+C stops watching, the game keeps going).")
    last_losses, bad, last_change = None, 0, time.time()
    try:
        while True:
            time.sleep(10)
            s, sess = api("GET", "/api/ps5/rp/session?passive=1")
            if not sess.get("host"):
                print("stream ended."); return
            s, live = api("GET", f"/api/ps5/rp/live/status?addr={ps5}")
            losses = live.get("losses")
            path, ms = via(ps5)
            lost_now = 0 if losses is None or last_losses is None else max(0, losses - last_losses)
            last_losses = losses if losses is not None else last_losses
            bad = bad + 1 if lost_now > 0 else 0
            print(f"{time.strftime('%H:%M:%S')} {path:8} {('%.0f ms' % ms) if ms is not None else '  ? ms':>7}"
                  f"  losses +{lost_now}  {t[0]}")
            if bad >= 2 and t is not TIERS[-1] and time.time() - last_change > 60:
                lower = pick_tier({"path": path, "rtt": ms, "jit": m["jit"]}, up, below=t[0])
                print(f"  stuttering -> stepping down to {describe(lower)}")
                api("POST", "/api/ps5/rp/stop", {"host": ps5, "session": sess.get("session")})
                s, d = start(ps5, lower)
                if d.get("ok"):
                    t, bad, last_change, last_losses = lower, 0, time.time(), None
                else:
                    print("  restart failed:", d.get("error") or d.get("code"), "- try PS5Upload > Play")
                    return
            elif bad == 0 and ms is not None and t is not TIERS[0]:
                better = pick_tier({"path": path, "rtt": ms, "jit": m["jit"]}, up)
                if TIERS.index(better) < TIERS.index(t) and int(time.time()) % 120 < 10:
                    print(f"  line looks good enough for {better[0]} - restart play to use it")
    except KeyboardInterrupt:
        print("\nstopped watching (stream still running).")

def cmd_invite(a):
    need_engine()
    ps5 = pick_console(a.ps5)
    if not ps5: sys.exit("no PS5 in PS5Upload - add it first (ps5u-buddy check)")
    s, tn = api("GET", "/api/tailnet")
    tip = ps5
    s, pt = api("GET", f"/api/ps5/tailnet?addr={ps5}", timeout=15)
    if pt.get("ip"): tip = pt["ip"]
    for k in tn.get("consoles", []):
        if ps5 in (k.get("host"), k.get("ip"), k.get("name")):
            tip = k.get("ip") or k.get("name") or tip
    up = a.upload or load_conf().get("upload_mbps") or 0
    j = json.dumps({"v": 2, "ps5": tip, "up": float(up)}, separators=(",", ":"))
    print("PS5B2:" + base64.b64encode(j.encode()).decode())
    print("Also: PS5Upload > Connection > the PS5's card > Invite a device, so your friend is let in.",
          file=sys.stderr)

def cmd_normal_invite(a):
    need_engine()
    ps5 = pick_console(a.ps5)
    if not ps5: sys.exit("no PS5 in PS5Upload - add it first (ps5u-buddy check)")
    up = a.upload or load_conf().get("upload_mbps") or 0
    link, msg, tip = normal_invite(ps5, float(up))
    print(msg)
    if not tip:
        print("\nNote: the PS5 isn't on Tailscale yet, so this only works on your home network.", file=sys.stderr)
    print("\nLet them in when they ask: PS5Upload > Connection > the PS5's card > Invite a device.",
          file=sys.stderr)

def cmd_tailscale_mode(a):
    need_engine()
    s, d = set_tailscale_mode(a.mode)
    if s != 200:
        sys.exit(f"failed: {d.get('error') or s}")
    sysd = d.get("system") or {}
    if a.mode == "system":
        if sysd.get("detected"):
            print(f"PS5Upload now uses the normal Tailscale app ({sysd.get('ip') or sysd.get('iface')}).")
        else:
            print("Set to the normal Tailscale app, but it isn't running on this computer.\n"
                  "Install it from https://tailscale.com/download and sign in, then run `ps5u-buddy check`.")
    else:
        print("PS5Upload uses its own built-in Tailscale. Turn it on: `ps5u-buddy tailscale-on`.")

def cmd_set(a):
    c = load_conf()
    if a.ps5: c["ps5"] = a.ps5
    if a.upload: c["upload_mbps"] = a.upload
    save_conf(c); print(c)

def main():
    p = argparse.ArgumentParser(prog="ps5u-buddy", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    for name, fn in (("check", cmd_check), ("play", cmd_play), ("invite", cmd_invite), ("set", cmd_set)):
        x = sp.add_parser(name); x.set_defaults(f=fn); x.add_argument("--ps5")
        if name in ("play", "invite", "set"): x.add_argument("--upload", type=float)
        if name == "play": x.add_argument("--no-adapt", action="store_true")
    x = sp.add_parser("tailscale-on"); x.set_defaults(f=cmd_tailscale_on); x.add_argument("--authkey")
    x = sp.add_parser("normal-invite"); x.set_defaults(f=cmd_normal_invite)
    x.add_argument("--ps5"); x.add_argument("--upload", type=float)
    x = sp.add_parser("tailscale-mode"); x.set_defaults(f=cmd_tailscale_mode)
    x.add_argument("mode", choices=["builtin", "system"])
    a = p.parse_args()
    a.f(a)

if __name__ == "__main__":
    main()

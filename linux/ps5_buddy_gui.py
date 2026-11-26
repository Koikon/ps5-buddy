#!/usr/bin/env python3
"""PS5 Buddy 2 - Linux GUI (GTK4 + libadwaita) for PS5Upload's built-in Tailscale.

Same as the Windows app: Play page (invite, connection rows, line test, latency graph,
PLAY at the best quality, auto step-down on stutter) and Host page (PS5 Tailscale check,
upload measure, invite code, Play Together guests). All engine calls run off the UI
thread. Logic (tiers, engine API, settings) comes from ps5u_buddy.py next to this file.
"""
import base64, json, os, subprocess, sys, tempfile, threading, time, urllib.parse, urllib.request
from collections import deque

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import ps5u_buddy as core                                     # noqa: E402

import gi                                                      # noqa: E402
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk           # noqa: E402

APP_ID = "io.github.koikon.PS5Buddy"
REPO = "Koikon/ps5-buddy"
LINUX_CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
                          "ps5buddy", "linux.conf")
TIERS = core.TIERS
TIER_NAMES = [t[0] for t in TIERS]


def version():
    for p in (os.path.join(HERE, "VERSION"), os.path.join(HERE, "..", "windows", "setup", "gui.ps1")):
        try:
            txt = open(p).read()
        except OSError:
            continue
        if p.endswith("VERSION"):
            return txt.strip()
        for line in txt.splitlines():
            if line.startswith("$Version = '"):
                return line.split("'")[1]
    return "0"


VERSION = version()


def linux_conf(key):
    try:
        for line in open(LINUX_CONF):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def q(s):
    return urllib.parse.quote(str(s), safe="")


def tier_text(t):
    return f"{t[0]}:  {t[2]}p / {t[3]} fps / {t[4]} kbps / {t[5].upper()}"


def vercmp(a):
    try:
        return tuple(int(x) for x in a.split("."))
    except ValueError:
        return (0,)


CSS = b"""
label.good, row.good label.subtitle { color: #5adc8c; }
label.warn, row.warn label.subtitle { color: #ffbe50; }
label.bad,  row.bad  label.subtitle { color: #ff6464; }
.tier { font-size: 17pt; font-weight: bold; }
.live { font-weight: bold; }
.logview text { font-family: monospace; font-size: 9pt; }
.graph { border-radius: 10px; }
"""


class Win(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=f"PS5 Buddy {VERSION}")
        self.set_default_size(820, 860)
        self.S = core.load_conf()
        self.S.setdefault("auto_lower", True)
        self.hist = deque(maxlen=60)
        self.path = "?"
        self.playing = None          # {"tier", "session"}
        self.last_loss, self.bad_win, self.last_change = None, 0, 0.0
        self.busy = False
        self.in_tick = False
        self.tick = 0

        css = Gtk.CssProvider()
        css.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.stack = Adw.ViewStack()
        self.stack.add_titled_with_icon(self.build_play(), "play", "Play", "media-playback-start-symbolic")
        self.stack.add_titled_with_icon(self.build_host(), "host", "Host (PS5 is at my house)", "network-server-symbolic")
        sw = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        header = Adw.HeaderBar(title_widget=sw)
        menu = Gio.Menu()
        menu.append("Check for updates", "win.update")
        menu.append("About PS5 Buddy", "win.about")
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu))
        for name, fn in (("update", lambda *_: self.check_update(True)), ("about", self.about)):
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", fn)
            self.add_action(a)

        # log at the bottom
        self.logbuf = Gtk.TextBuffer()
        lv = Gtk.TextView(buffer=self.logbuf, editable=False, cursor_visible=False,
                          wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=6, bottom_margin=6,
                          left_margin=8, right_margin=8)
        lv.add_css_class("logview")
        self.logmark = self.logbuf.create_mark("end", self.logbuf.get_end_iter(), False)
        self.logview = lv
        logsw = Gtk.ScrolledWindow(child=lv, min_content_height=96, vexpand=False)
        logframe = Gtk.Frame(child=logsw, margin_start=12, margin_end=12, margin_bottom=12)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.stack.set_vexpand(True)
        body.append(self.stack)
        body.append(logframe)
        tv = Adw.ToolbarView(content=body)
        tv.add_top_bar(header)
        self.set_content(tv)

        GLib.timeout_add(2000, self.on_tick)
        GLib.idle_add(self.on_start)

    # ------------------------------------------------------------ helpers
    def log(self, msg):
        def do():
            self.logbuf.insert(self.logbuf.get_end_iter(), f"[{time.strftime('%H:%M:%S')}] {msg}\n")
            self.logbuf.move_mark(self.logmark, self.logbuf.get_end_iter())
            self.logview.scroll_mark_onscreen(self.logmark)
        GLib.idle_add(do)

    def ui(self, fn, *a):
        GLib.idle_add(lambda: (fn(*a), False)[1])

    def run_bg(self, fn, exclusive=True):
        """Run fn in a thread. exclusive: refuse while another step is still running."""
        if exclusive:
            if self.busy:
                self.log("Still working on the last step - one moment.")
                return
            self.busy = True
            self.set_cursor_from_name("progress")

        def wrap():
            try:
                fn()
            except Exception as e:                     # keep the app alive on any surprise
                self.log(f"error: {e}")
            finally:
                if exclusive:
                    self.busy = False
                    self.ui(self.set_cursor_from_name, None)
        threading.Thread(target=wrap, daemon=True).start()

    def save(self):
        core.save_conf(self.S)

    @staticmethod
    def set_row(row, text, cls=None):
        def do():
            row.set_subtitle(GLib.markup_escape_text(text))
            for c in ("good", "warn", "bad"):
                row.remove_css_class(c)
            if cls:
                row.add_css_class(cls)
        GLib.idle_add(do)

    def row(self, group, title, button=None, cb=None):
        r = Adw.ActionRow(title=title, subtitle="?")
        r.set_subtitle_selectable(True)
        if button:
            b = Gtk.Button(label=button, valign=Gtk.Align.CENTER)
            b.connect("clicked", cb)
            r.add_suffix(b)
        group.add(r)
        return r

    @staticmethod
    def page(*children):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, margin_top=18, margin_bottom=12,
                      margin_start=12, margin_end=12)
        for c in children:
            box.append(c)
        clamp = Adw.Clamp(child=box, maximum_size=760)
        return Gtk.ScrolledWindow(child=clamp, hscrollbar_policy=Gtk.PolicyType.NEVER)

    # ------------------------------------------------------------ PLAY page
    def build_play(self):
        inv = Adw.PreferencesGroup(title="Invite code from the host",
                                   description="Optional. It adds the host's PS5 and their upload speed.")
        self.invite = Adw.EntryRow(title="PS5B2:...")
        b = Gtk.Button(label="Use invite", valign=Gtk.Align.CENTER)
        b.add_css_class("suggested-action")
        b.connect("clicked", self.on_invite)
        self.invite.add_suffix(b)
        self.invite.connect("entry-activated", self.on_invite)
        inv.add(self.invite)

        con = Adw.PreferencesGroup(title="Connection")
        self.r_engine = self.row(con, "PS5Upload", "Open PS5Upload", self.on_open)
        self.ts_mode = Adw.ComboRow(title="Tailscale type",
                                    subtitle="Built-in: PS5Upload signs in by itself. Normal: uses the Tailscale app.",
                                    model=Gtk.StringList.new(["PS5Upload built-in", "Normal Tailscale app"]))
        self.ts_mode_sync = False
        self.ts_mode.connect("notify::selected", self.on_ts_mode)
        con.add(self.ts_mode)
        self.r_ts = self.row(con, "Tailscale", "Turn on Tailscale", self.on_ts_on)
        self.r_ps5 = self.row(con, "PS5")
        self.r_path = self.row(con, "Path")
        self.r_link = self.row(con, "PS5 network")
        self.r_up = self.row(con, "House upload")

        self.tier_lbl = Gtk.Label(label="Press Test line", xalign=0, wrap=True)
        self.tier_lbl.add_css_class("tier")
        self.tier_lbl.add_css_class("accent")
        self.tier_d = Gtk.Label(label="", xalign=0, wrap=True)
        self.tier_d.add_css_class("dim-label")

        self.graph = Gtk.DrawingArea(content_height=90, hexpand=True)
        self.graph.set_draw_func(self.draw_graph)
        gframe = Gtk.Frame(child=self.graph)
        gframe.add_css_class("graph")

        btns = Gtk.Box(spacing=8, homogeneous=False)
        bt = Gtk.Button(label="Test line")
        bt.connect("clicked", self.on_test)
        bp = Gtk.Button(label="PLAY  (best quality)", hexpand=True)
        bp.add_css_class("suggested-action")
        bp.add_css_class("pill")
        bp.connect("clicked", self.on_play)
        bs = Gtk.Button(label="Stop")
        bs.add_css_class("destructive-action")
        bs.connect("clicked", self.on_stop)
        for w in (bt, bp, bs):
            w.set_size_request(-1, 42)
            btns.append(w)

        opt = Gtk.Box(spacing=10)
        self.auto = Gtk.Switch(active=bool(self.S.get("auto_lower", True)), valign=Gtk.Align.CENTER)
        self.auto.connect("notify::active", self.on_auto)
        opt.append(self.auto)
        opt.append(Gtk.Label(label="Auto-lower on stutter"))
        self.live = Gtk.Label(label="", xalign=1, hexpand=True)
        self.live.add_css_class("live")
        opt.append(self.live)

        return self.page(inv, con, self.tier_lbl, self.tier_d, gframe, btns, opt)

    def draw_graph(self, area, cr, w, h):
        vals = list(self.hist)
        nn = [v for v in vals if v is not None]
        mx = max([40.0] + nn)
        cr.set_source_rgba(0.5, 0.5, 0.5, 0.08)
        cr.rectangle(0, 0, w, h)
        cr.fill()
        cr.set_source_rgba(0.6, 0.6, 0.6, 0.9)
        cr.select_font_face("Sans")
        cr.set_font_size(11)
        cr.move_to(8, 15)
        cr.show_text(f"Tailscale ping to PS5 (max {int(mx)} ms)" + (f"   now {nn[-1]:.0f} ms" if nn else ""))
        if len(vals) < 2:
            return
        step = w / 59
        cr.set_source_rgb(0.35, 0.86, 0.55)
        cr.set_line_width(2)
        for i in range(1, len(vals)):
            a, b = vals[i - 1], vals[i]
            if a is None or b is None:
                continue
            cr.move_to((i - 1) * step, h - (a / mx) * (h - 24) - 3)
            cr.line_to(i * step, h - (b / mx) * (h - 24) - 3)
            cr.stroke()

    # ------------------------------------------------------------ engine state
    def ps5upload_path(self):
        p = linux_conf("PS5UPLOAD")
        return p if p and os.access(p, os.X_OK) else None

    def launch_ps5upload(self):
        p = self.ps5upload_path()
        if not p:
            self.log("PS5Upload not found - run the PS5 Buddy installer again.")
            return False
        env = dict(os.environ)
        if linux_conf("EXTRACT") == "1":
            env["APPIMAGE_EXTRACT_AND_RUN"] = "1"
        subprocess.Popen([p], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        return True

    def refresh_rows(self):
        if not core.engine_up():
            self.set_row(self.r_engine, "not running - press Open PS5Upload", "bad")
            self.set_row(self.r_ts, "?")
            return False
        self.set_row(self.r_engine, "running", "good")
        _, tn = core.api("GET", "/api/tailnet")
        mode = core.tailscale_mode(tn)
        self.mode = mode

        def sync():
            self.ts_mode_sync = True
            self.ts_mode.set_selected(1 if mode == "system" else 0)
            self.ts_mode_sync = False
        GLib.idle_add(sync)
        sysd = tn.get("system") or {}
        if mode == "system":
            if sysd.get("detected"):
                self.set_row(self.r_ts, f"normal Tailscale app on, this PC {sysd.get('ip') or sysd.get('iface')}", "good")
            else:
                self.set_row(self.r_ts, "normal Tailscale app not running - press Turn on Tailscale to get it", "warn")
        elif tn.get("enabled") and tn.get("signed_in") and tn.get("ip"):
            self.set_row(self.r_ts, f"on, this PC {tn['ip']}", "good")
        elif tn.get("login_url"):
            self.set_row(self.r_ts, "waiting for sign-in (browser)", "warn")
        else:
            self.set_row(self.r_ts, "off - press Turn on Tailscale (needed only to play away from home)", "warn")
        if not self.S.get("ps5"):
            p = core.pick_console(None)
            if p:
                self.S["ps5"] = p
                self.save()
        if self.S.get("ps5"):
            self.set_row(self.r_ps5, self.S["ps5"], "good")
        else:
            self.set_row(self.r_ps5, "none yet - use an invite, or PS5Upload > Connection > Add a PS5", "warn")
        up = float(self.S.get("upload_mbps") or 0)
        if up > 0:
            self.set_row(self.r_up, f"{up:g} Mbps -> stream may use up to {int(up * 1000 * core.UPLOAD_SHARE)} kbps")
        else:
            self.set_row(self.r_up, "unknown (host: Host page > Measure; friend: use the invite)")
        return True

    def refresh_link(self):
        ps5 = self.S.get("ps5")
        if not ps5:
            return
        _, lh = core.api("GET", f"/api/ps5/link-history?addr={q(ps5)}&read_link=1", timeout=10)
        lk = lh.get("link")
        kind = (lk.get("kind") if isinstance(lk, dict) else lk) or "unknown"
        drops = sum(1 for e in lh.get("events", []) or [] if e.get("kind") == "drop")
        if str(kind).lower() == "wifi":
            self.set_row(self.r_link, f"Wi-Fi (plug the PS5 into ethernet = biggest lag fix)  drops today: {drops}", "warn")
        elif str(kind).lower() == "wired":
            self.set_row(self.r_link, f"wired  drops today: {drops}", "good")
        else:
            self.set_row(self.r_link, f"unknown  drops today: {drops}")

    def sample(self):
        ps5 = self.S.get("ps5")
        if not ps5:
            return
        self.path, ms = core.via(q(ps5))
        self.hist.append(ms)

    def stats(self):
        g = [v for v in self.hist if v is not None]
        if not g:
            return {"path": self.path, "rtt": None, "jit": None}
        rtt = sorted(g)[len(g) // 2]
        d = [abs(a - b) for a, b in zip(g[1:], g[:-1])]
        return {"path": self.path, "rtt": round(rtt, 1), "jit": round(sum(d) / len(d), 1) if d else 0.0}

    def show_line(self):
        m = self.stats()
        names = {"direct": "DIRECT Tailscale", "relayed": "RELAYED Tailscale (slower)",
                 "lan": "same home network", "system": "system Tailscale app"}
        cls = {"direct": "good", "lan": "good", "relayed": "warn"}.get(self.path)
        rt = f"{m['rtt']} ms, jitter {m['jit']} ms" if m["rtt"] is not None else "no latency yet"
        self.set_row(self.r_path, f"{names.get(self.path, self.path)}  -  {rt}", cls)
        self.ui(self.graph.queue_draw)
        return m

    def set_tier(self, t, detail=""):
        i = TIER_NAMES.index(t[0])
        cls = "good" if i <= 1 else "warn" if t[0] == "SMOOTH" else "bad"

        def do():
            self.tier_lbl.set_label(tier_text(t))
            for c in ("good", "warn", "bad", "accent"):
                self.tier_lbl.remove_css_class(c)
            self.tier_lbl.add_css_class(cls)
            self.tier_d.set_label(detail)
        GLib.idle_add(do)

    # ------------------------------------------------------------ play actions
    def on_start(self):
        def go():
            if not core.engine_up():
                if self.launch_ps5upload():
                    self.log("Starting PS5Upload...")
                for _ in range(40):
                    if core.engine_up():
                        break
                    time.sleep(0.5)
            self.refresh_rows()
            self.refresh_link()
            self.log(f"PS5 Buddy {VERSION} ready. Friend: Turn on Tailscale > Use invite > Test line > PLAY. "
                     "Host: Host page.")
            self.check_update(False)
        self.run_bg(go)
        return False

    def on_open(self, *_):
        def go():
            if not self.launch_ps5upload():
                return
            self.log("Opening PS5Upload...")
            for _ in range(40):
                if core.engine_up():
                    break
                time.sleep(0.5)
            self.refresh_rows()
        self.run_bg(go)

    def on_ts_mode(self, row, _):
        if self.ts_mode_sync:
            return
        mode = "system" if row.get_selected() == 1 else "builtin"

        def go():
            if not core.engine_up():
                self.log("Open PS5Upload first.")
                return
            s, d = core.set_tailscale_mode(mode)
            if s != 200:
                self.log(f"Tailscale type: {d.get('error') or s}")
            elif mode == "system":
                det = (d.get("system") or {}).get("detected")
                self.log("PS5Upload now uses the normal Tailscale app." if det else
                         "Set to the normal Tailscale app - it isn't running here yet. Press Turn on Tailscale.")
            else:
                self.log("PS5Upload uses its built-in Tailscale. Press Turn on Tailscale to sign it in.")
            self.refresh_rows()
        self.run_bg(go)

    def on_ts_on(self, *_):
        def go():
            if not core.engine_up():
                self.log("Open PS5Upload first.")
                return
            if getattr(self, "mode", "builtin") == "system":
                _, tn = core.api("GET", "/api/tailnet")
                sysd = tn.get("system") or {}
                if sysd.get("detected"):
                    self.log(f"Normal Tailscale app is on ({sysd.get('ip')}).")
                else:
                    self.log("Install the Tailscale app and sign in (opening tailscale.com/download). "
                             "Linux: curl -fsSL https://tailscale.com/install.sh | sh  then  sudo tailscale up")
                    self.ui(Gtk.UriLauncher.new("https://tailscale.com/download").launch, self, None, None, None)
                self.refresh_rows()
                return
            s, r = core.api("POST", "/api/tailnet", {"op": "enable"}, timeout=30)
            if r.get("error"):
                self.log(f"Tailscale: {r['error']}")
                return
            self.log("Tailscale starting inside PS5Upload...")
            for _ in range(40):
                time.sleep(0.5)
                _, tn = core.api("GET", "/api/tailnet")
                if tn.get("login_url"):
                    self.ui(Gtk.UriLauncher.new(tn["login_url"]).launch, self, None, None, None)
                    self.log("Sign in to Tailscale in the browser (friend: the account the host invited you to).")
                    self.log(f"Sign-in link: {tn['login_url']}")
                    break
                if tn.get("ip"):
                    self.log(f"Tailscale on: {tn['ip']}")
                    break
            self.refresh_rows()
        self.run_bg(go)

    def on_invite(self, *_):
        code = self.invite.get_text().strip()
        if not code.startswith("PS5B2:"):
            self.log("That is not a PS5 Buddy 2 invite code (it starts with PS5B2:).")
            return
        try:
            j = json.loads(base64.b64decode(code[6:]).decode())
            ps5, up = str(j["ps5"]), float(j.get("up") or 0)
        except Exception as e:
            self.log(f"Bad invite code: {e}")
            return

        def go():
            self.S["upload_mbps"] = up
            s, r = core.api("POST", "/api/tailnet/consoles/add", {"addr": ps5, "name": "Host PS5"}, timeout=20)
            self.S["ps5"] = ps5
            if r.get("error"):
                self.log(f"Add PS5: {r['error']} (turn on Tailscale first, and have the host let you in)")
            else:
                _, d = core.api("GET", "/api/consoles")
                items = d if isinstance(d, list) else d.get("consoles", []) if isinstance(d, dict) else []
                for c in items:
                    if ps5 in json.dumps(c):
                        self.S["ps5"] = c.get("addr") or c.get("host") or ps5
                self.log(f"PS5 added ({r.get('action', 'ok')}): {self.S['ps5']}")
            self.save()
            self.ui(self.invite.set_text, "")
            self.refresh_rows()
            self.refresh_link()
        self.run_bg(go)

    def on_test(self, *_):
        def go():
            if not self.refresh_rows():
                return
            if not self.S.get("ps5"):
                self.log("No PS5 yet.")
                return
            self.hist.clear()
            for _ in range(10):
                self.sample()
                self.show_line()
                time.sleep(0.4)
            m = self.show_line()
            self.refresh_link()
            t = core.pick_tier(m, float(self.S.get("upload_mbps") or 0))
            extra = "  Relayed link: the host should enable UPnP on the router." if self.path == "relayed" else ""
            self.set_tier(t, "PLAY starts PS5Upload at exactly this quality." + extra)
            self.log(f"Line: {self.path}, {m['rtt']} ms, jitter {m['jit']} -> {t[0]}")
        self.run_bg(go)

    def start_tier(self, t):
        s, r = core.start(self.S["ps5"], t)
        if r.get("ok"):
            self.playing = {"tier": t, "session": r.get("session")}
            self.last_loss, self.bad_win, self.last_change = None, 0, time.time()
            self.log(f"Playing at {tier_text(t)} (session {r.get('session')})")
            return True
        why = r.get("code") or r.get("error") or f"status {s}"
        self.log(f"Start failed: {why}")
        if "no_credentials" in str(why):
            self.log("Pair first: PS5Upload > Play > Set up (one time, needs the PIN from the PS5).")
        if "busy" in str(why):
            self.log("The PS5 is busy (another stream, or it just stopped: try again in 30 s).")
        return False

    def on_play(self, *_):
        def go():
            if not self.refresh_rows():
                self.log("Open PS5Upload first.")
                return
            if not self.S.get("ps5"):
                self.log("No PS5 yet.")
                return
            if len(self.hist) < 5:
                for _ in range(8):
                    self.sample()
                    time.sleep(0.3)
            m = self.show_line()
            t = core.pick_tier(m, float(self.S.get("upload_mbps") or 0))
            self.set_tier(t, "Starting PS5Upload Play at this quality...")
            if self.start_tier(t):
                self.launch_ps5upload()
                self.log("Switch to PS5Upload > Play to see and control the game.")
        self.run_bg(go)

    def on_stop(self, *_):
        def go():
            body = {"host": self.S.get("ps5")}
            if self.playing:
                body["session"] = self.playing["session"]
            core.api("POST", "/api/ps5/rp/stop", body)
            self.playing = None
            self.ui(self.live.set_label, "")
            self.log("Stopped.")
        self.run_bg(go, exclusive=False)

    def on_auto(self, sw, _):
        self.S["auto_lower"] = sw.get_active()
        self.save()

    def watch_stream(self):
        if not self.playing:
            return
        ps5 = self.S["ps5"]
        _, sess = core.api("GET", "/api/ps5/rp/session?passive=1", timeout=5)
        if not sess.get("host"):
            self.playing = None
            self.ui(self.live.set_label, "stream ended")
            self.log("Stream ended.")
            return
        _, live = core.api("GET", f"/api/ps5/rp/live/status?addr={q(ps5)}", timeout=5)
        loss, new = live.get("losses"), 0
        if loss is not None and self.last_loss is not None:
            new = max(0, int(loss) - int(self.last_loss))
        if loss is not None:
            self.last_loss = loss
        self.bad_win = self.bad_win + 1 if new > 0 else 0
        t = self.playing["tier"]
        txt = f"LIVE  {t[0]}  losses +{new}  " + ("stutter" if self.bad_win else "smooth")

        def show():
            self.live.set_label(txt)
            self.live.remove_css_class("good")
            self.live.remove_css_class("warn")
            self.live.add_css_class("warn" if self.bad_win else "good")
        GLib.idle_add(show)
        if (self.bad_win >= 2 and self.S.get("auto_lower", True) and t[0] != "SAFE"
                and time.time() - self.last_change > 60):
            lower = core.pick_tier(self.stats(), float(self.S.get("upload_mbps") or 0), below=t[0])
            self.log(f"Stuttering -> stepping down to {tier_text(lower)}")
            Gdk.Display.get_default().beep()
            core.api("POST", "/api/ps5/rp/stop", {"host": ps5, "session": self.playing["session"]})
            if self.start_tier(lower):
                self.set_tier(lower, "Lowered automatically after stutter.")
                self.log("If the picture froze, press Play again in PS5Upload to rejoin.")
            else:
                self.playing = None

    # ------------------------------------------------------------ HOST page
    def build_host(self):
        intro = Gtk.Label(label="Your PS5 runs PS5Upload's Tailscale itself, so the stream leaves on your "
                                "house upload. No PC in the middle.", xalign=0, wrap=True)
        intro.add_css_class("dim-label")

        g1 = Adw.PreferencesGroup(title="1. PS5 on Tailscale",
                                  description="Not on yet: PS5Upload > Connection > the PS5 card > "
                                              "Put this PS5 on Tailscale.")
        self.h_ts = self.row(g1, "PS5 Tailscale", "Check", self.on_host_check)
        self.h_link = self.row(g1, "PS5 network")

        g2 = Adw.PreferencesGroup(title="2. Your upload",
                                  description="The PS5 streams on this line. PS5 Buddy keeps the stream "
                                              "under 60% of it.")
        self.h_up = Adw.EntryRow(title="Upload (Mbps)")
        up = self.S.get("upload_mbps")
        self.h_up.set_text(f"{float(up):g}" if up else "")
        self.h_up.connect("changed", self.on_up_changed)
        bm = Gtk.Button(label="Measure", valign=Gtk.Align.CENTER)
        bm.connect("clicked", self.on_measure)
        self.h_up.add_suffix(bm)
        g2.add(self.h_up)

        g3 = Adw.PreferencesGroup(title="3. Invite your friend",
                                  description="Also let them in: PS5Upload > Connection > PS5 card > "
                                              "Invite a device.")
        self.h_code = Adw.ActionRow(title="Invite code", subtitle="press Copy invite code")
        self.h_code.set_subtitle_selectable(True)
        bc = Gtk.Button(label="Copy invite code", valign=Gtk.Align.CENTER)
        bc.add_css_class("suggested-action")
        bc.connect("clicked", self.on_make_invite)
        self.h_code.add_suffix(bc)
        g3.add(self.h_code)

        g3b = Adw.PreferencesGroup(title="Friend without PS5 Buddy (plain PS5Upload)",
                                   description="PS5Upload's own invite link, plus the no-lag settings to "
                                               "set in their PS5Upload > Play > Settings.")
        self.h_normal = Adw.ActionRow(title="PS5Upload invite link", subtitle="press Copy")
        self.h_normal.set_subtitle_selectable(True)
        bl = Gtk.Button(label="Copy link", valign=Gtk.Align.CENTER)
        bl.connect("clicked", lambda *_: self.on_normal_invite(False))
        bn = Gtk.Button(label="Copy link + no-lag settings", valign=Gtk.Align.CENTER)
        bn.add_css_class("suggested-action")
        bn.connect("clicked", lambda *_: self.on_normal_invite(True))
        self.h_normal.add_suffix(bl)
        self.h_normal.add_suffix(bn)
        g3b.add(self.h_normal)
        self.h_settings = Adw.ExpanderRow(title="No-lag settings for them", subtitle="Picture, bitrate, low latency")
        g3b.add(self.h_settings)
        self.h_settings_rows = []

        g4 = Adw.PreferencesGroup(title="4. Play Together guests",
                                  description="Players 2-4 joining your stream, with their ping.")
        self.h_watch = Adw.SwitchRow(title="Watch guests")
        g4.add(self.h_watch)
        self.h_guests = Adw.ActionRow(title="Guests", subtitle="-")
        g4.add(self.h_guests)

        return self.page(intro, g1, g2, g3, g3b, g4)

    def on_up_changed(self, e):
        try:
            v = float(e.get_text().strip().replace(",", "."))
        except ValueError:
            return
        if v > 0:
            self.S["upload_mbps"] = v
            self.save()

    def on_host_check(self, *_):
        def go():
            if not self.refresh_rows():
                self.set_row(self.h_ts, "Open PS5Upload first (Play page)", "bad")
                return
            ps5 = self.S.get("ps5")
            if not ps5:
                self.set_row(self.h_ts, "Add your PS5 in PS5Upload first (Connection > Add a PS5)", "warn")
                return
            _, r = core.api("GET", f"/api/ps5/tailnet?addr={q(ps5)}", timeout=15)
            name = r.get("name") or r.get("hostname")
            if r.get("ip"):
                self.set_row(self.h_ts, f"on as {name} ({r['ip']}), state {r.get('state')}", "good")
            elif r.get("error"):
                self.set_row(self.h_ts, str(r["error"]), "warn")
            else:
                self.set_row(self.h_ts, f"off ({r.get('state')})", "warn")
            self.refresh_link()
            self.ui(lambda: self.set_row(self.h_link, self.r_link.get_subtitle() or "?"))
        self.run_bg(go)

    def on_measure(self, *_):
        def go():
            self.log("Measuring upload (2 x 25 MB to speed.cloudflare.com)...")
            buf, best = b"\0" * 25_000_000, None
            for _ in range(2):
                t0 = time.time()
                try:
                    req = urllib.request.Request("https://speed.cloudflare.com/__up", data=buf, method="POST",
                                                 headers={"Content-Type": "application/octet-stream",
                                                          "User-Agent": "ps5-buddy"})
                    urllib.request.urlopen(req, timeout=90).read()
                except Exception as e:
                    self.log(f"Upload test failed: {e}")
                    continue
                mbps = round(len(buf) * 8 / 1e6 / (time.time() - t0), 1)
                best = mbps if best is None else min(best, mbps)
            if best is None:
                self.log("Could not measure - type your upload in Mbps instead.")
                return
            self.S["upload_mbps"] = best
            self.save()
            self.ui(self.h_up.set_text, f"{best:g}")
            self.log(f"Upload: {best} Mbps (the PS5 uses this same line)")
            self.refresh_rows()
        self.run_bg(go)

    def on_make_invite(self, *_):
        def go():
            ps5 = self.S.get("ps5")
            if not ps5:
                self.log("Add your PS5 in PS5Upload first.")
                return
            target = ps5
            _, r = core.api("GET", f"/api/ps5/tailnet?addr={q(ps5)}", timeout=15)
            if r.get("ip"):
                target = r["ip"]
            elif r.get("name"):
                target = r["name"]
            else:
                self.log("Note: PS5 Tailscale not confirmed - your friend can't reach it until it is on.")
            up = float(self.S.get("upload_mbps") or 0)
            j = json.dumps({"v": 2, "ps5": target, "up": up}, separators=(",", ":"))
            code = "PS5B2:" + base64.b64encode(j.encode()).decode()

            def show():
                self.get_clipboard().set(code)
                self.h_code.set_subtitle(code)
            GLib.idle_add(show)
            self.log(f"Invite code copied ({target}, {up:g} Mbps). Send it to your friend.")
        self.run_bg(go)

    def on_normal_invite(self, with_settings):
        def go():
            ps5 = self.S.get("ps5") or core.pick_console(None)
            if not ps5:
                self.log("Add your PS5 in PS5Upload first (Connection > Add a PS5).")
                return
            up = float(self.S.get("upload_mbps") or 0)
            link, msg, tip = core.normal_invite(ps5, up)
            sets = core.low_lag_settings(up)

            def show():
                self.get_clipboard().set(msg if with_settings else link)
                self.h_normal.set_subtitle(link)
                for r in self.h_settings_rows:
                    self.h_settings.remove(r)
                self.h_settings_rows = []
                for k, v in sets.items():
                    r = Adw.ActionRow(title=k, subtitle=v)
                    self.h_settings.add_row(r)
                    self.h_settings_rows.append(r)
                self.h_settings.set_expanded(True)
            GLib.idle_add(show)
            self.log(("PS5Upload invite + no-lag settings copied." if with_settings else "PS5Upload invite link copied.")
                     + " Send it to your friend.")
            if not tip:
                self.log("Note: your PS5 isn't on Tailscale yet, so the link only works on your home network.")
            self.log("When they open it, let them in: PS5Upload > Connection > the PS5's card > Invite a device.")
        self.run_bg(go)

    def watch_guests(self):
        ps5 = self.S.get("ps5")
        if not ps5:
            return
        _, j = core.api("GET", f"/api/join?addr={q(ps5)}", timeout=5)
        if not j.get("open"):
            self.set_row(self.h_guests, "Play Together is not open (start Play in PS5Upload, then open Play Together).")
            return
        lines = []
        for g in j.get("guests", []) or []:
            rt = g.get("rtt_ms")
            tag = "" if rt is None else "smooth" if rt <= 40 else "ok" if rt <= 80 else \
                "laggy - lower the bitrate in PS5Upload (\"Lower to\")"
            lines.append(f"{g.get('name')}  ping {rt} ms  {tag}")
        self.set_row(self.h_guests, "\n".join(lines) if lines else "No guests yet.")

    # ------------------------------------------------------------ timer
    def on_tick(self):
        if self.in_tick or self.busy:
            return True
        self.in_tick = True
        self.tick += 1
        n, page = self.tick, self.stack.get_visible_child_name()
        watch = self.h_watch.get_active()

        def go():
            try:
                if page == "play" and self.S.get("ps5") and n % 2 == 0:
                    self.sample()
                    self.show_line()
                if self.playing and n % 5 == 0:
                    self.watch_stream()
                if page == "host" and watch and n % 2 == 0:
                    self.watch_guests()
                if n % 15 == 0:
                    self.refresh_rows()
            except Exception as e:
                self.log(f"error: {e}")
            finally:
                self.in_tick = False
        threading.Thread(target=go, daemon=True).start()
        return True

    # ------------------------------------------------------------ updates
    def check_update(self, manual):
        def go():
            try:
                req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases/latest",
                                             headers={"User-Agent": "ps5-buddy-updater"})
                rel = json.load(urllib.request.urlopen(req, timeout=15))
            except Exception as e:
                if manual:
                    self.log(f"Update check failed: {e}")
                return
            latest = str(rel.get("tag_name", "")).lstrip("v")
            names = {a.get("name") for a in rel.get("assets", [])}
            if vercmp(latest) <= vercmp(VERSION):
                if manual:
                    self.log(f"PS5 Buddy {VERSION} is up to date.")
                return
            if "install-linux.sh" not in names:
                if manual:
                    self.log(f"PS5 Buddy {latest} is out, but has no Linux build.")
                return
            if not manual and self.S.get("skip_version") == latest:
                self.log(f"Update {latest} skipped (menu > Check for updates to get it).")
                return
            notes = (rel.get("body") or "")[:700]
            self.ui(self.ask_update, latest, notes)
        threading.Thread(target=go, daemon=True).start()

    def ask_update(self, latest, notes):
        d = Adw.AlertDialog(heading=f"PS5 Buddy {latest} is available",
                            body=f"You have {VERSION}.\n\n{notes}")
        d.add_response("skip", "Skip this version")
        d.add_response("later", "Later")
        d.add_response("install", "Install")
        d.set_response_appearance("install", Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("install")

        def done(dlg, res):
            r = dlg.choose_finish(res)
            if r == "skip":
                self.S["skip_version"] = latest
                self.save()
            elif r == "install":
                self.install_update(latest)
        d.choose(self, None, done)

    def install_update(self, latest):
        def go():
            self.log(f"Downloading PS5 Buddy {latest}...")
            tmp = tempfile.mkdtemp(prefix="ps5buddy-update-")
            sh = os.path.join(tmp, "install.sh")
            try:
                urllib.request.urlretrieve(f"https://github.com/{REPO}/releases/download/v{latest}/install-linux.sh", sh)
            except Exception as e:
                self.log(f"Download failed: {e}")
                return
            # the installer verifies the release tarball's SHA-256 before replacing anything
            p = subprocess.run(["bash", sh, "--no-launch"], capture_output=True, text=True,
                               env={**os.environ, "TERM": "dumb"})
            for line in (p.stdout + p.stderr).splitlines()[-6:]:
                if line.strip() and not line.startswith("="):
                    self.log(line.strip())
            if p.returncode != 0:
                self.log(f"Update failed - PS5 Buddy {VERSION} is still installed.")
                return
            self.S["skip_version"] = ""
            self.save()
            self.log(f"Updated to {latest} - restarting.")
            exe = os.path.join(HERE, "ps5_buddy_gui.py")
            subprocess.Popen([sys.executable, exe], start_new_session=True)
            self.ui(self.get_application().quit)
        self.run_bg(go)

    def about(self, *_):
        a = Adw.AboutDialog(application_name="PS5 Buddy", version=VERSION, application_icon="input-gaming",
                            comments="Low-lag PS5Upload Play over PS5Upload's built-in Tailscale.",
                            website=f"https://github.com/{REPO}")
        a.present(self)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        w = self.get_active_window() or Win(self)
        w.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv[:1]))

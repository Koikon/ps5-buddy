# PS5 Buddy 2

Low-lag PS5 play with a friend, using **[PS5Upload](https://github.com/phantomptr/ps5upload)'s
built-in Tailscale** on a jailbroken PS5.

The PS5 itself joins your Tailscale network (PS5Upload helper), so the game stream goes
**straight from the PS5's upload** to your friend: no PC in the middle, no port forwarding.
PS5 Buddy drives the PS5Upload engine on the player's computer (`http://127.0.0.1:19113`)
to get the most out of that link.

| Part | What it does |
|---|---|
| **Connection** | Turns on PS5Upload's Tailscale, adds the host's PS5 from an invite code, shows the path (direct / relayed / home), the latency, and whether the PS5 is wired or on Wi-Fi |
| **Algorithm** | Measures Tailscale latency and jitter to the PS5 and caps the stream at 60% of the house upload. It picks the best tier, from 1080p60 15 Mbps H.265 down to 720p30 3 Mbps H.264, and **starts PS5Upload Play at exactly that quality**. While you play it reads the stream's packet losses and **steps down a tier** after two 10-second windows with losses. It never raises the quality by itself, because a restart interrupts play |
| **Acceleration** | PS5Upload traffic gets top priority (DSCP EF), Windows network throttling is turned off, the power plan is set to High performance and the firewall is opened for direct Tailscale links. It also flags Wi-Fi on the PS5 or the PC and relayed links |

## Windows: one-click install

Download `PS5-Buddy-Windows.zip` from [Releases](../../releases), unzip it and double-click
**Install.bat**. It installs PS5Upload, which already includes Tailscale, plus the PS5 Buddy app,
with shortcuts on the desktop and in the Start menu. To remove it, use Settings > Apps.

- **Play tab (friend):** Turn on Tailscale → Use invite → Test line → **PLAY**. It shows a live latency graph and has an "Auto-lower on stutter" option.
- **Host tab:** checks that the PS5 is on Tailscale and whether it's wired, measures your upload, copies the invite code, and shows each Play Together guest's ping.

## Friend without PS5 Buddy (plain PS5Upload)

Host tab/page > **copy its invite + no-lag settings** makes PS5Upload's own invite link
(`ps5upload://console?n=…&h=…&t=…&k=…`, the same as PS5Upload > Connection > Invite a device). Your
friend opens it, or pastes it in PS5Upload > Connection > Add a PS5, and you let them in. A
PS5Upload link can't carry stream settings, because each PS5Upload keeps its own. So the copied
text also lists the no-lag settings for their PS5Upload > Play > Settings: Low latency on, Lower
quality on a busy network on, 60 fps, and a picture size and bitrate that fit your upload. CLI:
`ps5u-buddy normal-invite`.

## Tailscale type

PS5 Buddy works with either kind of Tailscale. Pick it under **Tailscale type** (CLI:
`ps5u-buddy tailscale-mode builtin|system`):

- **PS5Upload built-in**: PS5Upload signs in as its own Tailscale device. Nothing else to install.
- **Normal Tailscale app**: PS5Upload uses the Tailscale app already on the computer
  (tailscale.com/download). Use this if you already run Tailscale for other things.

## Updates

PS5 Buddy checks this repo's latest release each time it opens and asks before installing it. It
verifies the zip against the `.sha256` file in the same release, replaces only its own files (a
backup is kept in `%LOCALAPPDATA%\PS5Buddy\previous`), runs `setup/post-update.ps1` if a release
includes one, and restarts. **Check for updates** checks by hand. PS5Upload updates itself.

To publish an update for everyone: `./release.sh 2.1.1 "what changed"`

## Linux: one-command install

```
curl -fsSL https://github.com/Koikon/ps5-buddy/releases/latest/download/install-linux.sh | bash
```

Or download `PS5-Buddy-Linux.tar.gz` from [Releases](../../releases), unpack it and run `./install.sh`.
No root needed. It installs PS5Upload's AppImage (checksum verified, or it reuses a PS5Upload you
already have), the **PS5 Buddy** app (in your app launcher, or run `ps5-buddy`) and the `ps5u-buddy`
CLI. The app is a GTK4/libadwaita window with the same Play and Host pages as on Windows: invite, connection
check, live latency graph, PLAY at the best quality with auto step-down, upload measure, invite code,
Play Together guests and update prompts. Without GTK4/libadwaita 1.5+ it opens a terminal menu instead
(`ps5-buddy --menu` forces that). To remove it, run `~/.local/share/ps5buddy/uninstall.sh`. It removes PS5Upload only
if the installer put it there.

## CLI (Linux / macOS): `ps5u_buddy.py`

Uses the same engine API, with no dependencies:

```
ps5u-buddy check                 # connection report + what to fix
ps5u-buddy tailscale-on          # turn on PS5Upload's Tailscale, prints the sign-in link
ps5u-buddy set --upload 38       # house upload in Mbps (the PS5's stream ceiling)
ps5u-buddy play                  # best quality + adaptive step-down
ps5u-buddy invite                # PS5B2: code for a friend's PS5 Buddy
```

## Notes

- You need a jailbroken PS5 with the PS5Upload helper running, paired once in PS5Upload > Play > Set up.
- **Two ways to play together.** In the first, your friend streams the PS5 while you play on the console itself. In the second, PS5Upload's Play Together lets friends join your stream as Players 2–4.
- Remote Play is a video stream, so game-level rollback netcode isn't possible. Distance sets a floor on ping. In the same city, a direct link is typically 5–15 ms.
- `classic/` holds v1 for a stock PS5: a PC subnet-routes the PS5 over system Tailscale to chiaki-ng, with CAKE autorate.

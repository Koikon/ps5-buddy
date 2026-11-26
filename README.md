# PS5 Buddy

Low-lag PS5 Remote Play with a friend over a private Tailscale network.

A PS5 can't run Tailscale, so the host's PC joins Tailscale **for** it and
routes only the PS5's address to the friend. The video still comes from the PS5
and leaves on the house upload. PS5 Buddy makes that path as fast as possible
and picks the best stream quality the line can hold.

| Part | What it does |
|---|---|
| **Connection** | PS5 shared as a `/32` Tailscale subnet route, pinned UDP 41641 for direct links, firewall/ACL opened only for Remote Play ports |
| **Acceleration** | Stream marked top priority (DSCP EF), no Windows network throttling, high-performance power. Linux host also gets a CAKE queue on the uplink and UDP GRO forwarding |
| **Algorithm** | Measures ping, jitter, loss, relay vs direct and the host's upload; picks a tier (1080p60 15 Mbps down to 540p60 3 Mbps) capped at 60% of upload; re-checks live and only switches after the change holds. Linux host: latency-based autorate steers CAKE's limit in real time |

## Windows (friend and/or host): GUI app

`windows/` is the install package. Zip it or build it with
`./make-buddy-pack.sh --ps5 <PS5 IP>` → `dist/PS5-Buddy-Windows.zip`.

Double-click **Install.bat** → installs Tailscale, chiaki-ng and the PS5 Buddy
app (desktop + Start menu, uninstall from Settings > Apps).

- **Play tab** — paste the host's invite code, Connect, Test line, PLAY. Live ping graph + quality advice.
- **Host tab** — find PS5, measure upload, share PS5 on Tailscale, speed boost, copy invite, watch the friend's line (bufferbloat warning).

The app is PowerShell + WinForms, so it runs on any Windows 10/11 with nothing extra.

## Linux host: `ps5buddy.py`

```
ps5buddy find                        # find the PS5 on the LAN
sudo ps5buddy setup --ps5 <IP>       # connection + acceleration (persistent)
ps5buddy invite [--authkey KEY]      # code for the friend's app
sudo ps5buddy watch                  # live autorate + friend tier
ps5buddy status | sudo ps5buddy off
```

## Tailscale policy

`tailnet-policy-snippet.hujson`: friend devices (`tag:buddy`) may reach only the
PS5's Remote Play ports. Approve the PS5 route once in the admin console.

## Limits

- One Remote Play stream per PS5: the host plays on the console, the friend streams.
- Remote Play is a video stream, so game-level rollback netcode isn't possible.
- Physical distance sets a ping floor; same-city direct links are typically 5–15 ms.

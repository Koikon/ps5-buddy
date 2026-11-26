# PS5 Buddy - connection check + adaptive settings picker + launcher
# The "algorithm": measure ping, jitter and loss through the tunnel, pick the
# best chiaki-ng stream tier that line can hold, keep re-checking while you play.
param([switch]$TestOnly)
$ErrorActionPreference = 'Continue'
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tsExe  = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

function Read-Ini($path) {
  $h = @{}
  foreach ($line in Get-Content $path) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $h[$matches[1]] = $matches[2] }
  }
  return $h
}
$cfg = Read-Ini (Join-Path $appDir 'buddy.ini')
$ps5 = $cfg['PS5_IP']; $hostNode = $cfg['HOST_NODE']
# The PS5 sends the stream on the host's upload. Use at most 60% of it so the
# host's house can still browse/chat without the stream stuttering.
$upMbps = 0; [void][double]::TryParse([string]$cfg['UPLOAD_MBPS'], [ref]$upMbps)
$capKbps = if ($upMbps -gt 0) { [int]($upMbps * 1000 * 0.6) } else { 999999 }

# Stream tiers, best first. Limits = what the line must stay under.
$Tiers = @(
  @{ Name='ULTRA';  Res='1080p'; Fps=60; Kbps=15000; Codec='H265 (HEVC)'; Rtt=20; Jit=4;  Loss=0 },
  @{ Name='HIGH';   Res='1080p'; Fps=60; Kbps=10000; Codec='H265 (HEVC)'; Rtt=35; Jit=7;  Loss=1 },
  @{ Name='SMOOTH'; Res='720p';  Fps=60; Kbps=6000;  Codec='H265 (HEVC)'; Rtt=60; Jit=12; Loss=2 },
  @{ Name='SAFE';   Res='540p';  Fps=60; Kbps=3000;  Codec='H264';        Rtt=999;Jit=999;Loss=100 }
)

function Measure-Line {
  $r = @{ Direct=$null; Via='?'; Rtt=999; Jit=999; Loss=100 }
  if ($hostNode) {
    $out = & $tsExe ping --c 3 $hostNode 2>&1 | Out-String
    if ($out -match 'via DERP\(([^)]+)\)') { $r.Direct=$false; $r.Via="relay $($matches[1])" }
    elseif ($out -match 'via (\S+)') { $r.Direct=$true; $r.Via="direct $($matches[1])" }
  }
  $pings = @(); $sent = 20
  $ping = New-Object System.Net.NetworkInformation.Ping
  for ($i=0; $i -lt $sent; $i++) {
    try { $p = $ping.Send($ps5, 1000); if ($p.Status -eq 'Success') { $pings += [double]$p.RoundtripTime } } catch {}
    Start-Sleep -Milliseconds 100
  }
  if ($pings.Count -gt 0) {
    $r.Loss = [math]::Round(100 * ($sent - $pings.Count) / $sent, 1)
    $r.Rtt  = [math]::Round(($pings | Measure-Object -Average).Average, 1)
    $d = @(); for ($i=1; $i -lt $pings.Count; $i++) { $d += [math]::Abs($pings[$i]-$pings[$i-1]) }
    if ($d.Count) { $r.Jit = [math]::Round(($d | Measure-Object -Average).Average, 1) } else { $r.Jit = 0 }
  }
  return $r
}

function Pick-Tier($m) {
  foreach ($t in $Tiers) {
    if ($m.Rtt -le $t.Rtt -and $m.Jit -le $t.Jit -and $m.Loss -le $t.Loss) {
      # A relayed link adds hops and wobble: never allow the top tier over a relay
      if ($m.Direct -eq $false -and $t.Name -eq 'ULTRA') { continue }
      # Must fit in the host's upload (the PS5's outgoing pipe)
      if ($t.Kbps -gt $capKbps -and $t.Name -ne 'SAFE') { continue }
      return $t
    }
  }
  return $Tiers[-1]
}

function Show($m, $t) {
  Write-Host ''
  Write-Host ("  Tunnel : {0}" -f $m.Via)
  if ($upMbps -gt 0) { Write-Host ("  Host upload: {0} Mbps (stream allowed up to {1} kbps)" -f $upMbps, $capKbps) }
  Write-Host ("  Ping   : {0} ms   Jitter: {1} ms   Loss: {2}%" -f $m.Rtt, $m.Jit, $m.Loss)
  Write-Host ''
  Write-Host ("  >>> {0}: set chiaki-ng to {1} / {2} fps / {3} kbps / {4}" -f $t.Name,$t.Res,$t.Fps,$t.Kbps,$t.Codec) -ForegroundColor Green
  if ($m.Direct -eq $false) { Write-Host '  ! Link is RELAYED. Ask the host to forward UDP 41641 to their PC for a direct link.' -ForegroundColor Yellow }
  if ($m.Loss -ge 100)      { Write-Host "  ! Can't reach the PS5 ($ps5). Is it on / in rest mode, and is the host's PC online?" -ForegroundColor Red }
}

# ---- checks ----
Write-Host 'PS5 Buddy' -ForegroundColor Magenta
$st = $null; try { $st = & $tsExe status --json | ConvertFrom-Json } catch {}
if (-not $st -or $st.BackendState -ne 'Running') {
  Write-Host 'Tailscale is off - starting it...' -ForegroundColor Yellow
  & $tsExe up --accept-routes --unattended | Out-Null
  Start-Sleep 3
}
$wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 9 }
$wired = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 14 }
if ($wifi -and -not $wired) { Write-Host '  ! You are on Wi-Fi. An ethernet cable is the single biggest lag fix.' -ForegroundColor Yellow }

Write-Host 'Measuring the line to the PS5...'
$m = Measure-Line; $t = Pick-Tier $m; Show $m $t
if ($TestOnly) { return }

# ---- launch + keep watching ----
$chiaki = Get-Content (Join-Path $appDir 'chiaki-path.txt') -ErrorAction SilentlyContinue
if (-not $chiaki -or -not (Test-Path $chiaki)) { Write-Host 'chiaki-ng not found - run Install.bat again.' -ForegroundColor Red; pause; return }
Write-Host ''
Write-Host "PS5 address: $ps5  (add it in chiaki-ng with the + button the first time)" -ForegroundColor Cyan
$proc = Start-Process $chiaki -PassThru
Write-Host 'Watching the line while you play (this window can stay minimized)...'
$cur = $t.Name; $bad = 0
while (-not $proc.HasExited) {
  Start-Sleep -Seconds 15
  if ($proc.HasExited) { break }
  $m2 = Measure-Line; $t2 = Pick-Tier $m2
  if ($t2.Name -ne $cur) {
    # only report a change if it holds for 2 checks in a row (ignore one-off spikes)
    $bad++
    if ($bad -ge 2) {
      [console]::beep(880,200)
      Write-Host ("[{0}] line changed -> {1}" -f (Get-Date -Format HH:mm), $t2.Name) -ForegroundColor Yellow
      Show $m2 $t2
      $cur = $t2.Name; $bad = 0
    }
  } else { $bad = 0 }
}
Write-Host 'chiaki-ng closed. Bye!'

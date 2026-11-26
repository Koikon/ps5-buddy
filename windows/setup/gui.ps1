# PS5 Buddy - Windows GUI (Play mode for the friend, Host mode for the PS5 owner)
# Pure PowerShell 5.1 + WinForms: runs on any Windows 10/11, nothing else needed.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'

$AppDir  = Join-Path $env:LOCALAPPDATA 'PS5Buddy'
$SetFile = Join-Path $AppDir 'settings.json'
$TsExe   = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

# ---------------------------------------------------------------- settings
function Load-Settings {
  $s = @{ ps5_ip=''; host_node=''; upload_mbps=0; friend_node='' }
  if (Test-Path $SetFile) {
    try { $j = Get-Content $SetFile -Raw | ConvertFrom-Json
          foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value } } catch {}
  } else {
    $ini = Join-Path $AppDir 'buddy.ini'
    if (Test-Path $ini) {
      foreach ($l in Get-Content $ini) {
        if ($l -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') {
          switch ($matches[1]) { 'PS5_IP' {$s.ps5_ip=$matches[2]} 'HOST_NODE' {$s.host_node=$matches[2]}
                                 'UPLOAD_MBPS' { if ($matches[2]) {$s.upload_mbps=[double]$matches[2]} } }
        }
      }
    }
  }
  return $s
}
function Save-Settings { $script:S | ConvertTo-Json | Set-Content $SetFile }
$script:S = Load-Settings

# ---------------------------------------------------------------- tailscale helpers
function Ts-Status { try { return (& $TsExe status --json | Out-String | ConvertFrom-Json) } catch { return $null } }
function Ts-Run([string[]]$a) { if (Test-Path $TsExe) { return (& $TsExe @a 2>&1 | Out-String) } else { return 'Tailscale not installed' } }

# ---------------------------------------------------------------- the algorithm
# Tiers: name, kbps, max ping, max jitter, max loss %
$Tiers = @(
  @('ULTRA',  '1080p', 60, 15000, 20, 4, 0, 'H265 (HEVC)'),
  @('HIGH',   '1080p', 60, 10000, 35, 7, 1, 'H265 (HEVC)'),
  @('SMOOTH', '720p',  60, 6000,  60, 12, 2, 'H265 (HEVC)'),
  @('SAFE',   '540p',  60, 3000,  99999, 99999, 100, 'H264'))
function Pick-Tier($rtt, $jit, $loss, $direct, $capKbps) {
  foreach ($t in $Tiers) {
    if ($rtt -le $t[4] -and $jit -le $t[5] -and $loss -le $t[6] -and $t[3] -le $capKbps) {
      if ($direct -eq $false -and $t[0] -eq 'ULTRA') { continue }   # relays wobble: no top tier
      return $t
    }
  }
  return $Tiers[-1]
}
function Cap-Kbps { $u = [double]$script:S.upload_mbps; if ($u -gt 0) { return [int]($u * 1000 * 0.6) } else { return 999999 } }

# live measurement state
$script:Hist = New-Object System.Collections.ArrayList
$script:Path = '?'; $script:Direct = $null; $script:TsPing = $null; $script:LastTier = ''; $script:TierVotes = 0
$Pinger = New-Object System.Net.NetworkInformation.Ping

function Sample($target) {
  $r = $null
  try { $p = $Pinger.Send($target, 800); if ($p.Status -eq 'Success') { $r = [double]$p.RoundtripTime } } catch {}
  [void]$script:Hist.Add($r); while ($script:Hist.Count -gt 60) { $script:Hist.RemoveAt(0) }
}
function Stats {
  $g = @($script:Hist | Where-Object { $_ -ne $null })
  if ($g.Count -eq 0) { return @{ rtt=999; jit=999; loss=100; base=0; bloat=0; ok=$false } }
  $rtt = $g[-1]; $base = ($g | Measure-Object -Minimum).Minimum
  $d = @(); for ($i=1; $i -lt $g.Count; $i++) { $d += [math]::Abs($g[$i]-$g[$i-1]) }
  $jit = if ($d.Count) { [math]::Round(($d | Measure-Object -Average).Average,1) } else { 0 }
  $loss = [math]::Round(100 * ($script:Hist.Count - $g.Count) / $script:Hist.Count, 1)
  return @{ rtt=$rtt; jit=$jit; loss=$loss; base=$base; bloat=($rtt-$base); ok=$true }
}
# path check (direct vs relay) runs tailscale ping in the background, read on a later tick
function Start-PathCheck($node) {
  if (-not $node -or -not (Test-Path $TsExe)) { return }
  if ($script:TsPing -and -not $script:TsPing.HasExited) { return }
  $psi = New-Object Diagnostics.ProcessStartInfo $TsExe, "ping --c 2 --timeout 2s $node"
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
  $script:TsPing = [Diagnostics.Process]::Start($psi)
}
function Read-PathCheck {
  if ($script:TsPing -and $script:TsPing.HasExited) {
    $o = $script:TsPing.StandardOutput.ReadToEnd(); $script:TsPing = $null
    if ($o -match 'via DERP\(([^)]+)\)') { $script:Direct = $false; $script:Path = "RELAY ($($matches[1])) - slower" }
    elseif ($o -match 'via (\S+)') { $script:Direct = $true; $script:Path = "DIRECT $($matches[1])" }
    else { $script:Path = 'no answer' }
  }
}

# ---------------------------------------------------------------- UI helpers
$Dark = [Drawing.Color]::FromArgb(24,24,32); $Panel = [Drawing.Color]::FromArgb(36,36,48)
$Fg = [Drawing.Color]::Gainsboro; $Accent = [Drawing.Color]::FromArgb(120,140,255)
$Good = [Drawing.Color]::FromArgb(90,220,140); $Warn = [Drawing.Color]::FromArgb(255,190,80); $Bad = [Drawing.Color]::FromArgb(255,100,100)
$Font = New-Object Drawing.Font('Segoe UI', 10)

function L($parent, $text, $x, $y, $w=420, $h=22, $size=10, $bold=$false) {
  $l = New-Object Windows.Forms.Label; $l.Text=$text; $l.Location="$x,$y"; $l.Size="$w,$h"; $l.ForeColor=$Fg
  $st = if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
  $l.Font = New-Object Drawing.Font('Segoe UI', $size, $st); $parent.Controls.Add($l); return $l
}
function B($parent, $text, $x, $y, $w=150, $h=32) {
  $b = New-Object Windows.Forms.Button; $b.Text=$text; $b.Location="$x,$y"; $b.Size="$w,$h"
  $b.FlatStyle='Flat'; $b.BackColor=$Panel; $b.ForeColor=$Fg; $b.Font=$Font; $b.FlatAppearance.BorderColor=$Accent
  $parent.Controls.Add($b); return $b
}
function T($parent, $text, $x, $y, $w=200) {
  $t = New-Object Windows.Forms.TextBox; $t.Text=$text; $t.Location="$x,$y"; $t.Size="$w,26"
  $t.BackColor=$Panel; $t.ForeColor=$Fg; $t.BorderStyle='FixedSingle'; $t.Font=$Font; $parent.Controls.Add($t); return $t
}
function Log($msg) { $LogBox.AppendText("[$(Get-Date -Format HH:mm:ss)] $msg`r`n") }
function Busy([scriptblock]$sb) { $Form.Cursor='WaitCursor'; try { & $sb } catch { Log "error: $_" } finally { $Form.Cursor='Default' } }

# ---------------------------------------------------------------- window
$Form = New-Object Windows.Forms.Form
$Form.Text = 'PS5 Buddy'; $Form.Size = '760,700'; $Form.BackColor = $Dark; $Form.ForeColor = $Fg
$Form.StartPosition = 'CenterScreen'; $Form.FormBorderStyle = 'FixedSingle'; $Form.MaximizeBox = $false; $Form.Font = $Font
$chiaki = Get-Content (Join-Path $AppDir 'chiaki-path.txt') -ErrorAction SilentlyContinue
if ($chiaki -and (Test-Path $chiaki)) { try { $Form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($chiaki) } catch {} }

$Tabs = New-Object Windows.Forms.TabControl; $Tabs.Location='10,10'; $Tabs.Size='725,470'
$Form.Controls.Add($Tabs)
$TabPlay = New-Object Windows.Forms.TabPage; $TabPlay.Text = '  Play  '; $TabPlay.BackColor = $Dark
$TabHost = New-Object Windows.Forms.TabPage; $TabHost.Text = '  Host (PS5 is at my house)  '; $TabHost.BackColor = $Dark
$Tabs.TabPages.AddRange(@($TabPlay, $TabHost))

$LogBox = New-Object Windows.Forms.TextBox; $LogBox.Multiline=$true; $LogBox.ScrollBars='Vertical'; $LogBox.ReadOnly=$true
$LogBox.Location='10,490'; $LogBox.Size='725,160'; $LogBox.BackColor=$Panel; $LogBox.ForeColor=$Fg
$LogBox.Font = New-Object Drawing.Font('Consolas', 9); $Form.Controls.Add($LogBox)

# ================================================================ PLAY TAB
L $TabPlay 'Invite code from the host:' 15 15 220 | Out-Null
$InviteBox = T $TabPlay '' 15 40 540
$BtnInvite = B $TabPlay 'Use invite' 565 37 130

$LblTs    = L $TabPlay 'Tailscale: ?' 15 85 680
$LblPs5   = L $TabPlay 'PS5: ?' 15 110 680
$LblPath  = L $TabPlay 'Link: ?' 15 135 680
$LblLine  = L $TabPlay 'Ping: -   Jitter: -   Loss: -' 15 160 680
$LblUp    = L $TabPlay 'Host upload: ?' 15 185 680
$LblTier  = L $TabPlay 'Press Test line' 15 215 680 40 18 $true
$LblTier.ForeColor = $Accent
$LblTierD = L $TabPlay '' 15 255 680 22

$Graph = New-Object Windows.Forms.Panel; $Graph.Location='15,285'; $Graph.Size='680,85'; $Graph.BackColor=$Panel
$TabPlay.Controls.Add($Graph)

$BtnConnect = B $TabPlay 'Connect' 15 385 130
$BtnTest    = B $TabPlay 'Test line' 155 385 130
$BtnPlay    = B $TabPlay 'PLAY' 295 385 200 40
$BtnPlay.BackColor = [Drawing.Color]::FromArgb(60,70,160)
$ChkWatch   = New-Object Windows.Forms.CheckBox; $ChkWatch.Text='Keep watching the line'; $ChkWatch.Location='510,392'
$ChkWatch.Size='200,24'; $ChkWatch.ForeColor=$Fg; $ChkWatch.Checked=$true; $TabPlay.Controls.Add($ChkWatch)

$Graph.Add_Paint({
  param($s, $e)
  $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
  $vals = @($script:Hist); if ($vals.Count -lt 2) { return }
  $max = [math]::Max(40, (($vals | Where-Object { $_ -ne $null } | Measure-Object -Maximum).Maximum))
  $w = $Graph.Width; $h = $Graph.Height; $step = $w / 59
  $pen = New-Object Drawing.Pen($Good, 2)
  for ($i=1; $i -lt $vals.Count; $i++) {
    $x1 = ($i-1)*$step; $x2 = $i*$step
    if ($vals[$i] -eq $null) { $g.FillRectangle([Drawing.Brushes]::IndianRed, $x2-1, 0, 3, $h); continue }
    if ($vals[$i-1] -eq $null) { continue }
    $y1 = $h - ($vals[$i-1]/$max)*($h-6) - 3; $y2 = $h - ($vals[$i]/$max)*($h-6) - 3
    $g.DrawLine($pen, [float]$x1, [float]$y1, [float]$x2, [float]$y2)
  }
  $g.DrawString("ping (max $([int]$max) ms)", $Font, [Drawing.Brushes]::Gray, 4, 2)
})

function Refresh-Play {
  $st = Ts-Status
  if (-not (Test-Path $TsExe)) { $LblTs.Text = 'Tailscale: NOT INSTALLED (run Install.bat)'; $LblTs.ForeColor = $Bad }
  elseif ($st -and $st.BackendState -eq 'Running') { $LblTs.Text = "Tailscale: connected as $($st.Self.HostName)"; $LblTs.ForeColor = $Good }
  else { $LblTs.Text = 'Tailscale: not connected - press Connect'; $LblTs.ForeColor = $Warn }
  $LblPs5.Text = if ($script:S.ps5_ip) { "PS5: $($script:S.ps5_ip)   (host PC: $($script:S.host_node))" } else { 'PS5: unknown - paste the invite code from the host' }
  $LblUp.Text = if ($script:S.upload_mbps -gt 0) { "Host upload: $($script:S.upload_mbps) Mbps  -> stream may use up to $(Cap-Kbps) kbps" } else { 'Host upload: unknown (no cap)' }
}

function Show-Tier($target) {
  $m = Stats
  $LblLine.Text = "Ping: $($m.rtt) ms   Jitter: $($m.jit) ms   Loss: $($m.loss)%"
  $LblPath.Text = "Link: $($script:Path)"
  $LblPath.ForeColor = if ($script:Direct -eq $false) { $Warn } elseif ($script:Direct) { $Good } else { $Fg }
  if (-not $m.ok) { $LblTier.Text = "Can't reach $target"; $LblTier.ForeColor = $Bad; $LblTierD.Text = 'Is the PS5 on / in rest mode and the host PC online?'; return }
  $t = Pick-Tier $m.rtt $m.jit $m.loss $script:Direct (Cap-Kbps)
  # only switch the advice when it holds for 3 samples (ignore one-off spikes)
  if ($t[0] -ne $script:LastTier) { $script:TierVotes++ } else { $script:TierVotes = 0 }
  if ($script:LastTier -eq '' -or $script:TierVotes -ge 3) {
    if ($script:LastTier -ne '' -and $t[0] -ne $script:LastTier) { [Media.SystemSounds]::Asterisk.Play(); Log "line changed -> $($t[0])" }
    $script:LastTier = $t[0]; $script:TierVotes = 0
    $LblTier.Text = "$($t[0]):  $($t[1]) / $($t[2]) fps / $($t[3]) kbps / $($t[7])"
    $LblTier.ForeColor = switch ($t[0]) { 'ULTRA' {$Good} 'HIGH' {$Good} 'SMOOTH' {$Warn} default {$Bad} }
    $LblTierD.Text = 'Set this in chiaki-ng > Settings > Video.' + $(if ($script:Direct -eq $false) { '  Link is relayed: ask host to forward UDP 41641.' } else { '' })
  }
  $Graph.Invalidate()
}

$BtnInvite.Add_Click({
  $c = $InviteBox.Text.Trim()
  if ($c -notmatch '^PS5B1:(.+)$') { Log 'That is not a PS5 Buddy invite code.'; return }
  try {
    $j = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[1])) | ConvertFrom-Json
    $script:S.ps5_ip = $j.ps5; $script:S.host_node = $j.host; $script:S.upload_mbps = [double]$j.up
    Save-Settings; Log "Invite saved: PS5 $($j.ps5) via $($j.host), upload $($j.up) Mbps"
    if ($j.key) { Busy { Log (Ts-Run @('up','--accept-routes','--unattended',"--hostname=ps5-buddy-$($env:COMPUTERNAME.ToLower())","--authkey=$($j.key)")) } ; Log 'Joined the host network.' }
    $InviteBox.Text = ''; Refresh-Play
  } catch { Log "Bad invite code: $_" }
})

$BtnConnect.Add_Click({
  Busy {
    $st = Ts-Status
    if ($st -and $st.BackendState -eq 'Running') { Log (Ts-Run @('set','--accept-routes=true')); Log 'Connected (PS5 route on).' }
    else {
      Log 'Opening Tailscale login in your browser...'
      $psi = New-Object Diagnostics.ProcessStartInfo $TsExe, 'up --accept-routes --unattended'
      $psi.UseShellExecute=$false; $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true; $psi.CreateNoWindow=$true
      $p = [Diagnostics.Process]::Start($psi); $opened=$false; $deadline=(Get-Date).AddMinutes(3)
      $errTask = $p.StandardError.ReadLineAsync()
      while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200
        if ($errTask.IsCompleted) {
          $line = $errTask.Result
          if ($line -match '(https://login\.tailscale\.com/\S+)' -and -not $opened) { Start-Process $matches[1]; $opened=$true }
          if ($line -ne $null) { $errTask = $p.StandardError.ReadLineAsync() }
        }
      }
      Log 'Login finished.'
    }
  }
  Refresh-Play
})

$BtnTest.Add_Click({
  if (-not $script:S.ps5_ip) { Log 'Paste the invite code first.'; return }
  Busy {
    $script:Hist.Clear(); $script:LastTier=''; Start-PathCheck $script:S.host_node
    for ($i=0; $i -lt 15; $i++) { Sample $script:S.ps5_ip; [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150 }
    $w = 0; while ($script:TsPing -and -not $script:TsPing.HasExited -and $w -lt 30) { Start-Sleep -Milliseconds 100; $w++ }
    Read-PathCheck; Show-Tier $script:S.ps5_ip
    $m = Stats; Log "Test: ping $($m.rtt) ms, jitter $($m.jit), loss $($m.loss)%, $($script:Path) -> $($script:LastTier)"
  }
})

$BtnPlay.Add_Click({
  $c = Get-Content (Join-Path $AppDir 'chiaki-path.txt') -ErrorAction SilentlyContinue
  if (-not $c -or -not (Test-Path $c)) { Log 'chiaki-ng not found - run Install.bat again.'; return }
  Start-Process $c | Out-Null
  Log "chiaki-ng started. First time: + > add PS5 at $($script:S.ps5_ip), then Register with the PIN from the host."
  $ChkWatch.Checked = $true
})

# ================================================================ HOST TAB
L $TabHost '1. Your PS5' 15 15 300 24 11 $true | Out-Null
$HostIp  = T $TabHost $script:S.ps5_ip 15 45 180
$BtnFind = B $TabHost 'Find PS5' 205 42 120
$LblFind = L $TabHost '' 335 47 370

L $TabHost '2. Your upload (the PS5 stream uses it)' 15 90 400 24 11 $true | Out-Null
$HostUp  = T $TabHost ([string]$script:S.upload_mbps) 15 120 100
L $TabHost 'Mbps' 120 123 50 | Out-Null
$BtnMeas = B $TabHost 'Measure' 205 117 120

L $TabHost '3. Share + speed up' 15 165 400 24 11 $true | Out-Null
$BtnShare = B $TabHost 'Share PS5 on Tailscale' 15 195 220
$BtnBoost = B $TabHost 'Speed boost' 245 195 150
$LblShare = L $TabHost '' 405 200 300

L $TabHost '4. Invite your friend' 15 245 400 24 11 $true | Out-Null
L $TabHost 'Auth key (optional, one-off tag:buddy):' 15 275 270 | Out-Null
$HostKey = T $TabHost '' 290 272 260
$BtnMake = B $TabHost 'Copy invite' 560 269 135

L $TabHost '5. Watch your friend''s line' 15 320 400 24 11 $true | Out-Null
$FriendBox = New-Object Windows.Forms.ComboBox; $FriendBox.Location='15,350'; $FriendBox.Size='260,26'
$FriendBox.BackColor=$Panel; $FriendBox.ForeColor=$Fg; $FriendBox.Font=$Font; $TabHost.Controls.Add($FriendBox)
$BtnPeers = B $TabHost 'Refresh' 285 347 100
$ChkHostWatch = New-Object Windows.Forms.CheckBox; $ChkHostWatch.Text='Watch'; $ChkHostWatch.Location='400,352'
$ChkHostWatch.ForeColor=$Fg; $TabHost.Controls.Add($ChkHostWatch)
$LblHostW = L $TabHost '' 15 385 690 50 10 $true

$BtnFind.Add_Click({
  Busy {
    $u = New-Object Net.Sockets.UdpClient; $u.EnableBroadcast = $true; $u.Client.ReceiveTimeout = 2500
    $msg = [Text.Encoding]::ASCII.GetBytes("SRCH * HTTP/1.1`ndevice-discovery-protocol-version:00030010`n")
    [void]$u.Send($msg, $msg.Length, '255.255.255.255', 9302)
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    try {
      $d = [Text.Encoding]::ASCII.GetString($u.Receive([ref]$ep))
      $name = if ($d -match 'host-name:(.*)') { $matches[1].Trim() } else { 'PlayStation' }
      $state = if ($d -match ' 200 ') { 'awake' } else { 'rest mode' }
      $HostIp.Text = $ep.Address.ToString(); $LblFind.Text = "$name ($state)"; $LblFind.ForeColor = $Good
      Log "Found $name at $($ep.Address) ($state)"
    } catch { $LblFind.Text = 'Not found - is Remote Play on?'; $LblFind.ForeColor = $Bad
      Log 'PS5 not found. PS5: Settings > System > Remote Play ON; Power Saving > Rest Mode > Stay connected to internet.' }
    $u.Close()
  }
})

$BtnMeas.Add_Click({
  Busy {
    Log 'Measuring upload (2 x 25 MB to speed.cloudflare.com)...'
    $hc = New-Object Net.Http.HttpClient; $hc.Timeout = [TimeSpan]::FromSeconds(60)
    $buf = New-Object byte[] 25000000; $best = 99999
    for ($i=0; $i -lt 2; $i++) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $t = $hc.PostAsync('https://speed.cloudflare.com/__up', (New-Object Net.Http.ByteArrayContent(,$buf)))
      while (-not $t.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
      $mbps = [math]::Round(25000000*8/1e6 / $sw.Elapsed.TotalSeconds, 1)
      if ($mbps -lt $best) { $best = $mbps }
    }
    $HostUp.Text = [string]$best; Log "Upload: $best Mbps"
  }
})

$BtnShare.Add_Click({
  $ip = $HostIp.Text.Trim()
  if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { Log 'Enter or find the PS5 IP first.'; return }
  Busy {
    $script:S.ps5_ip = $ip; $script:S.upload_mbps = [double]$HostUp.Text; Save-Settings
    $st = Ts-Status
    if ($st -and $st.BackendState -eq 'Running') { Log (Ts-Run @('set',"--advertise-routes=$ip/32")) }
    else { Log 'Log in to Tailscale in the browser window...'; Start-Process $TsExe -ArgumentList 'up',"--advertise-routes=$ip/32",'--unattended' -Wait -WindowStyle Hidden }
    # Windows subnet routers: allow Remote Play ports through to the PS5
    Remove-NetFirewallRule -DisplayName 'PS5 Buddy route' -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'PS5 Buddy route' -Direction Inbound -InterfaceAlias 'Tailscale' -Protocol Any -Action Allow -ErrorAction SilentlyContinue | Out-Null
    $LblShare.Text = 'Shared. Approve the route once in the Tailscale admin page.'; $LblShare.ForeColor = $Good
    Log "PS5 $ip advertised. Admin console > Machines > this PC > Edit route settings > tick it."
    Start-Process 'https://login.tailscale.com/admin/machines'
  }
})

$BtnBoost.Add_Click({
  Busy {
    # top priority (DSCP 46) for Tailscale's packets = the PS5 stream to your friend
    $q = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS'
    New-Item $q -Force | Out-Null; Set-ItemProperty $q -Name 'Do not use NLA' -Value '1' -Type String
    Remove-NetQosPolicy -Name 'PS5Buddy-ts' -Confirm:$false -ErrorAction SilentlyContinue
    New-NetQosPolicy -Name 'PS5Buddy-ts' -AppPathNameMatchCondition 'tailscaled.exe' -DSCPAction 46 -NetworkProfile All | Out-Null
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord
    Set-ItemProperty $mm -Name SystemResponsiveness -Value 10 -Type DWord
    cmd /c "powercfg /setactive SCHEME_MIN >nul 2>nul"
    # let direct Tailscale links in (fewer relays)
    Remove-NetFirewallRule -DisplayName 'PS5 Buddy tailscale direct' -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'PS5 Buddy tailscale direct' -Direction Inbound -Protocol UDP -LocalPort 41641 -Action Allow | Out-Null
    Log 'Speed boost on: stream priority (DSCP EF), no network throttling, high-performance power, UDP 41641 open.'
    Log 'Best extra step: forward UDP 41641 on your router to this PC, and keep the PS5 + PC on ethernet.'
  }
})

$BtnMake.Add_Click({
  $st = Ts-Status
  $hostName = if ($st -and $st.Self) { $st.Self.HostName } else { $env:COMPUTERNAME.ToLower() }
  $ip = $HostIp.Text.Trim(); if (-not $ip) { Log 'Set the PS5 IP first.'; return }
  $o = [ordered]@{ ps5=$ip; host=$hostName; up=[double]$HostUp.Text; key=$HostKey.Text.Trim() }
  $code = 'PS5B1:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress)))
  [Windows.Forms.Clipboard]::SetText($code)
  Log 'Invite code copied. Send it to your friend privately (it may contain your auth key).'
})

function Fill-Peers {
  $FriendBox.Items.Clear(); $st = Ts-Status
  if ($st -and $st.Peer) { foreach ($p in $st.Peer.PSObject.Properties.Value) { if ($p.Online) { [void]$FriendBox.Items.Add($p.HostName) } } }
  if ($script:S.friend_node) { $FriendBox.Text = $script:S.friend_node } elseif ($FriendBox.Items.Count) { $FriendBox.SelectedIndex = 0 }
}
$BtnPeers.Add_Click({ Fill-Peers })
$ChkHostWatch.Add_CheckedChanged({ $script:Hist.Clear(); $script:LastTier=''; if ($FriendBox.Text) { $script:S.friend_node = $FriendBox.Text; Save-Settings } })

function Host-Tick {
  $f = $FriendBox.Text; if (-not $f) { return }
  $st = Ts-Status; $ip = $null
  if ($st -and $st.Peer) { foreach ($p in $st.Peer.PSObject.Properties.Value) { if ($p.HostName -eq $f) { $ip = $p.TailscaleIPs[0] } } }
  if (-not $ip) { $LblHostW.Text = "$f is offline"; return }
  Sample $ip; Read-PathCheck; if ($script:HostTicks++ % 10 -eq 0) { Start-PathCheck $f }
  $m = Stats; if (-not $m.ok) { $LblHostW.Text = "$f not answering"; return }
  $t = Pick-Tier $m.rtt $m.jit $m.loss $script:Direct (Cap-Kbps)
  # bufferbloat detector: ping rising above the line's best = your upload is clogged
  $bloat = [math]::Round($m.bloat,1)
  $adv = if ($bloat -gt 15) { 'UPLOAD CLOGGED - pause uploads/cloud sync/streams in the house' } else { 'line clean' }
  $LblHostW.ForeColor = if ($bloat -gt 15) { $Warn } else { $Good }
  $LblHostW.Text = "ping $($m.rtt) ms  jitter $($m.jit)  loss $($m.loss)%  bloat +$bloat ms  ($adv)`r`n$($script:Path)   friend should use: $($t[0]) $($t[1]) $($t[3]) kbps"
}
$script:HostTicks = 0

# ---------------------------------------------------------------- timer
$Timer = New-Object Windows.Forms.Timer; $Timer.Interval = 1000
$script:Tick = 0
$Timer.Add_Tick({
  $script:Tick++
  if ($Tabs.SelectedTab -eq $TabPlay -and $ChkWatch.Checked -and $script:S.ps5_ip) {
    Sample $script:S.ps5_ip; Read-PathCheck
    if ($script:Tick % 15 -eq 1) { Start-PathCheck $script:S.host_node }
    Show-Tier $script:S.ps5_ip
  } elseif ($Tabs.SelectedTab -eq $TabHost -and $ChkHostWatch.Checked) { Host-Tick }
  if ($script:Tick % 30 -eq 0) { Refresh-Play }
})
$Form.Add_Shown({
  Refresh-Play; Fill-Peers
  Log 'PS5 Buddy ready. Friend: paste invite > Test line > PLAY. Host: use the Host tab.'
  $Timer.Start()
})
$Form.Add_FormClosed({ $Timer.Stop() })
[void]$Form.ShowDialog()

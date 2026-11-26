# PS5 Buddy 2 - Windows GUI for PS5Upload (jailbroken PS5 with PS5Upload's built-in Tailscale)
# The PS5 is on Tailscale itself, so the stream goes straight from the PS5's upload to you.
# PS5 Buddy drives the PS5Upload engine on this PC (http://127.0.0.1:19113):
#   connection check -> line test -> start Play at the best quality -> step down on stutter.
# Pure PowerShell 5.1 + WinForms.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'

$AppDir  = Join-Path $env:LOCALAPPDATA 'PS5Buddy'
$SetFile = Join-Path $AppDir 'settings.json'
$Engine  = 'http://127.0.0.1:19113'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

# ---------------------------------------------------------------- settings
$script:S = @{ ps5=''; upload_mbps=0; ps5upload_exe='' ; auto_lower=$true }
if (Test-Path $SetFile) { try { $j = Get-Content $SetFile -Raw | ConvertFrom-Json
  foreach ($p in $j.PSObject.Properties) { $script:S[$p.Name] = $p.Value } } catch {} }
function Save-Settings { $script:S | ConvertTo-Json | Set-Content $SetFile }
if ($env:PS5UPLOAD_ENGINE) { $Engine = $env:PS5UPLOAD_ENGINE }

function Find-PS5Upload {
  if ($script:S.ps5upload_exe -and (Test-Path $script:S.ps5upload_exe)) { return $script:S.ps5upload_exe }
  $c = Get-ChildItem "$env:LOCALAPPDATA\PS5Upload","$env:LOCALAPPDATA\Programs","$env:ProgramFiles\PS5Upload","$AppDir\PS5Upload" `
        -Recurse -Filter 'PS5Upload.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $script:S.ps5upload_exe = $c.FullName; Save-Settings; return $c.FullName }
  return $null
}

# ---------------------------------------------------------------- engine API (non-blocking for the UI)
$Http = New-Object Net.Http.HttpClient; $Http.Timeout = [TimeSpan]::FromSeconds(75)
function Api([string]$method, [string]$path, $body = $null, [int]$timeoutSec = 20) {
  try {
    $req = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::new($method), "$Engine$path")
    if ($body -ne $null) { $req.Content = New-Object Net.Http.StringContent(($body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json') }
    $t = $Http.SendAsync($req); $deadline = (Get-Date).AddSeconds($timeoutSec)
    while (-not $t.IsCompleted -and (Get-Date) -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    if (-not $t.IsCompleted) { return @{ _status = 0; error = 'timeout' } }
    if ($t.IsFaulted) { return @{ _status = 0; error = 'PS5Upload not running' } }
    $r = $t.Result; $txt = $r.Content.ReadAsStringAsync().Result
    $o = if ($txt) { try { $txt | ConvertFrom-Json } catch { @{} } } else { @{} }
    if ($o -is [Management.Automation.PSCustomObject]) { $o | Add-Member -NotePropertyName _status -NotePropertyValue ([int]$r.StatusCode) -Force }
    return $o
  } catch { return @{ _status = 0; error = "$_" } }
}
function Engine-Up { $r = Api 'GET' '/api/tailnet' $null 3; return ($r._status -eq 200) }

# ---------------------------------------------------------------- the algorithm
# name, width, height, fps, kbps, codec, max ping, max jitter
$Tiers = @(
  @('ULTRA', 1920, 1080, 60, 15000, 'h265', 20, 4),
  @('HIGH',  1920, 1080, 60, 10000, 'h265', 35, 7),
  @('SMOOTH',1280,  720, 60,  6000, 'h265', 60, 12),
  @('SAFE',  1280,  720, 30,  3000, 'h264', 99999, 99999))
function Tier-Index($name) { for ($i=0; $i -lt $Tiers.Count; $i++) { if ($Tiers[$i][0] -eq $name) { return $i } }; return 0 }
function Pick-Tier($path, $rtt, $jit, $below = '') {
  $u = [double]$script:S.upload_mbps; $cap = if ($u -gt 0) { $u * 1000 * 0.6 } else { 999999 }
  $start = if ($below) { [math]::Min((Tier-Index $below) + 1, $Tiers.Count - 1) } else { 0 }
  if ($rtt -eq $null) { $rtt = 50 }; if ($jit -eq $null) { $jit = 8 }
  for ($i = $start; $i -lt $Tiers.Count; $i++) {
    $t = $Tiers[$i]
    if ($t[4] -gt $cap) { continue }                                   # must fit the PS5's (house) upload
    if ($path -eq 'lan') { return $t }                                 # at home: only the cap matters
    if ($path -eq 'relayed' -and $t[0] -eq 'ULTRA') { continue }       # relays wobble: no top tier
    if ($rtt -le $t[6] -and $jit -le $t[7]) { return $t }
  }
  return $Tiers[-1]
}
function Tier-Text($t) { return "$($t[0]):  $($t[2])p / $($t[3]) fps / $($t[4]) kbps / $($t[5].ToUpper())" }

$script:Hist = New-Object System.Collections.ArrayList
$script:Path = '?'
function Sample {
  if (-not $script:S.ps5) { return }
  $v = Api 'GET' "/api/tailnet/via?addr=$([uri]::EscapeDataString($script:S.ps5))" $null 5
  $script:Path = if ($v.via) { [string]$v.via } else { '?' }
  $ms = $null; if ($v.latency_ms -ne $null -and [double]$v.latency_ms -ge 0) { $ms = [double]$v.latency_ms }
  [void]$script:Hist.Add($ms); while ($script:Hist.Count -gt 60) { $script:Hist.RemoveAt(0) }
}
function Stats {
  $g = @($script:Hist | Where-Object { $_ -ne $null })
  if ($g.Count -eq 0) { return @{ rtt=$null; jit=$null } }
  $sorted = $g | Sort-Object; $rtt = $sorted[[int][math]::Floor($sorted.Count/2)]
  $d = @(); for ($i=1; $i -lt $g.Count; $i++) { $d += [math]::Abs($g[$i]-$g[$i-1]) }
  $jit = if ($d.Count) { [math]::Round(($d | Measure-Object -Average).Average,1) } else { 0 }
  return @{ rtt=[math]::Round($rtt,1); jit=$jit }
}

# ---------------------------------------------------------------- UI helpers
$Dark = [Drawing.Color]::FromArgb(20,20,30); $Panel = [Drawing.Color]::FromArgb(34,34,48)
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
function Set-Row($lbl, $text, $color) { $lbl.Text = $text; $lbl.ForeColor = $color }

# ---------------------------------------------------------------- window
$Form = New-Object Windows.Forms.Form
$Form.Text = 'PS5 Buddy 2  (PS5Upload + Tailscale)'; $Form.Size = '780,720'; $Form.BackColor = $Dark; $Form.ForeColor = $Fg
$Form.StartPosition = 'CenterScreen'; $Form.FormBorderStyle = 'FixedSingle'; $Form.MaximizeBox = $false; $Form.Font = $Font
$exe = Find-PS5Upload; if ($exe) { try { $Form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($exe) } catch {} }

$Tabs = New-Object Windows.Forms.TabControl; $Tabs.Location='10,10'; $Tabs.Size='745,500'; $Form.Controls.Add($Tabs)
$TabPlay = New-Object Windows.Forms.TabPage; $TabPlay.Text='  Play  '; $TabPlay.BackColor=$Dark
$TabHost = New-Object Windows.Forms.TabPage; $TabHost.Text='  Host (PS5 is at my house)  '; $TabHost.BackColor=$Dark
$Tabs.TabPages.AddRange(@($TabPlay, $TabHost))
$LogBox = New-Object Windows.Forms.TextBox; $LogBox.Multiline=$true; $LogBox.ScrollBars='Vertical'; $LogBox.ReadOnly=$true
$LogBox.Location='10,520'; $LogBox.Size='745,150'; $LogBox.BackColor=$Panel; $LogBox.ForeColor=$Fg
$LogBox.Font = New-Object Drawing.Font('Consolas', 9); $Form.Controls.Add($LogBox)

# ================================================================ PLAY TAB
L $TabPlay 'Invite code from the host (optional):' 15 12 300 | Out-Null
$InviteBox = T $TabPlay '' 15 36 560
$BtnInvite = B $TabPlay 'Use invite' 585 33 140

$RowEngine = L $TabPlay 'PS5Upload: ?' 15 80 520
$BtnOpen   = B $TabPlay 'Open PS5Upload' 585 75 140 28
$RowTs     = L $TabPlay 'Tailscale (in PS5Upload): ?' 15 110 520
$BtnTsOn   = B $TabPlay 'Turn on Tailscale' 585 105 140 28
$RowPs5    = L $TabPlay 'PS5: ?' 15 140 560
$RowPath   = L $TabPlay 'Path: ?' 15 165 700
$RowLink   = L $TabPlay 'PS5 network: ?' 15 190 700
$RowUp     = L $TabPlay 'House upload: ?' 15 215 700

$LblTier = L $TabPlay 'Press Test line' 15 245 710 36 17 $true; $LblTier.ForeColor = $Accent
$LblTierD = L $TabPlay '' 15 282 710 22

$Graph = New-Object Windows.Forms.Panel; $Graph.Location='15,308'; $Graph.Size='710,80'; $Graph.BackColor=$Panel; $TabPlay.Controls.Add($Graph)

$BtnTest  = B $TabPlay 'Test line' 15 400 130 40
$BtnPlay  = B $TabPlay 'PLAY  (best quality)' 155 400 230 40
$BtnPlay.BackColor = [Drawing.Color]::FromArgb(60,70,160)
$BtnStop  = B $TabPlay 'Stop' 395 400 90 40
$BtnBoost = B $TabPlay 'Speed boost' 495 400 120 40
$ChkAuto = New-Object Windows.Forms.CheckBox; $ChkAuto.Text='Auto-lower on stutter'; $ChkAuto.Location='15,448'
$ChkAuto.Size='220,24'; $ChkAuto.ForeColor=$Fg; $ChkAuto.Checked=[bool]$script:S.auto_lower; $TabPlay.Controls.Add($ChkAuto)
$LblLive = L $TabPlay '' 240 450 490

$Graph.Add_Paint({ param($s,$e)
  $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $vals = @($script:Hist); if ($vals.Count -lt 2) { return }
  $nn = @($vals | Where-Object { $_ -ne $null }); $max = 40; if ($nn.Count) { $max = [math]::Max(40, ($nn | Measure-Object -Maximum).Maximum) }
  $w = $Graph.Width; $h = $Graph.Height; $step = $w / 59; $pen = New-Object Drawing.Pen($Good, 2)
  for ($i=1; $i -lt $vals.Count; $i++) {
    if ($vals[$i] -eq $null -or $vals[$i-1] -eq $null) { continue }
    $y1 = $h - ($vals[$i-1]/$max)*($h-6) - 3; $y2 = $h - ($vals[$i]/$max)*($h-6) - 3
    $g.DrawLine($pen, [float](($i-1)*$step), [float]$y1, [float]($i*$step), [float]$y2)
  }
  $g.DrawString("Tailscale ping to PS5 (max $([int]$max) ms)", $Font, [Drawing.Brushes]::Gray, 4, 2)
})

function Refresh-Rows {
  if (-not (Engine-Up)) {
    Set-Row $RowEngine 'PS5Upload: not running - press Open PS5Upload' $Bad
    Set-Row $RowTs 'Tailscale (in PS5Upload): ?' $Fg; return $false
  }
  Set-Row $RowEngine 'PS5Upload: running' $Good
  $tn = Api 'GET' '/api/tailnet'
  if ($tn.enabled -and $tn.signed_in -and $tn.ip) { Set-Row $RowTs "Tailscale (in PS5Upload): on, this PC $($tn.ip)" $Good }
  elseif ($tn.login_url) { Set-Row $RowTs 'Tailscale: waiting for sign-in (browser)' $Warn }
  else { Set-Row $RowTs 'Tailscale (in PS5Upload): off - press Turn on Tailscale' $Warn }
  if (-not $script:S.ps5) {
    $cs = Api 'GET' '/api/consoles'
    $list = @(); if ($cs -is [array]) { $list = $cs } elseif ($cs.consoles) { $list = @($cs.consoles) }
    foreach ($c in $list) { $a = $c.addr; if (-not $a) { $a = $c.host }; if (-not $a) { $a = $c.ip }; if ($a) { $script:S.ps5 = [string]$a; Save-Settings; break } }
    if (-not $script:S.ps5 -and $tn.consoles) { $k = @($tn.consoles)[0]; $script:S.ps5 = [string]$(if ($k.ip) { $k.ip } else { $k.host }); Save-Settings }
  }
  if ($script:S.ps5) { Set-Row $RowPs5 "PS5: $($script:S.ps5)" $Good } else { Set-Row $RowPs5 'PS5: none yet - use the invite, or PS5Upload > Connection > Add a PS5' $Warn }
  if ([double]$script:S.upload_mbps -gt 0) { Set-Row $RowUp "House upload: $($script:S.upload_mbps) Mbps -> stream may use up to $([int]([double]$script:S.upload_mbps*600)) kbps" $Fg }
  else { Set-Row $RowUp 'House upload: unknown (ask the host for the invite code)' $Fg }
  return $true
}
function Refresh-Link {
  if (-not $script:S.ps5) { return }
  $lh = Api 'GET' "/api/ps5/link-history?addr=$([uri]::EscapeDataString($script:S.ps5))&read_link=1" $null 10
  $k = $null; if ($lh.link) { $k = $lh.link.kind }
  $drops = @($lh.events | Where-Object { $_.kind -eq 'drop' }).Count
  if ($k -eq 'wifi') { Set-Row $RowLink "PS5 network: Wi-Fi  (host: plug the PS5 into ethernet = biggest lag fix)  drops today: $drops" $Warn }
  elseif ($k -eq 'wired') { Set-Row $RowLink "PS5 network: wired  drops today: $drops" $Good }
  else { Set-Row $RowLink "PS5 network: unknown  drops today: $drops" $Fg }
}
function Show-Line {
  $m = Stats
  $pc = switch ($script:Path) { 'direct' {$Good} 'lan' {$Good} 'relayed' {$Warn} default {$Fg} }
  $rt = if ($m.rtt -ne $null) { "$($m.rtt) ms, jitter $($m.jit) ms" } else { 'no latency yet' }
  $pn = switch ($script:Path) { 'direct' {'DIRECT Tailscale'} 'relayed' {'RELAYED Tailscale (slower)'} 'lan' {'same home network'} 'system' {'system Tailscale app'} default {$script:Path} }
  Set-Row $RowPath "Path: $pn  -  $rt" $pc
  $Graph.Invalidate()
  return $m
}

$BtnOpen.Add_Click({
  $e = Find-PS5Upload
  if (-not $e) { Log 'PS5Upload not found - run Install.bat again.'; return }
  Start-Process $e | Out-Null; Log 'Starting PS5Upload...'
  Busy { for ($i=0; $i -lt 40 -and -not (Engine-Up); $i++) { Start-Sleep -Milliseconds 500 } }
  Refresh-Rows | Out-Null
})

$BtnTsOn.Add_Click({
  Busy {
    $r = Api 'POST' '/api/tailnet' @{ op = 'enable' } 30
    if ($r.error) { Log "Tailscale: $($r.error)"; return }
    Log 'Tailscale starting inside PS5Upload...'
    for ($i=0; $i -lt 40; $i++) {
      Start-Sleep -Milliseconds 500; [Windows.Forms.Application]::DoEvents()
      $tn = Api 'GET' '/api/tailnet'
      if ($tn.login_url) { Start-Process $tn.login_url; Log 'Sign in to Tailscale in the browser (use the account the host invited you to).'; break }
      if ($tn.ip) { Log "Tailscale on: $($tn.ip)"; break }
    }
  }
  Refresh-Rows | Out-Null
})

$BtnInvite.Add_Click({
  $c = $InviteBox.Text.Trim()
  if ($c -notmatch '^PS5B2:(.+)$') { Log 'That is not a PS5 Buddy 2 invite code (starts with PS5B2:).'; return }
  try {
    $j = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[1])) | ConvertFrom-Json
    $script:S.upload_mbps = [double]$j.up
    Busy {
      $r = Api 'POST' '/api/tailnet/consoles/add' @{ addr = [string]$j.ps5; name = 'Host PS5' } 20
      if ($r.error) { Log "Add PS5: $($r.error) (turn on Tailscale first, and have the host let you in)"; $script:S.ps5 = [string]$j.ps5 }
      else {
        # use the console-list entry PS5Upload made (its home address when it knows it)
        $script:S.ps5 = [string]$j.ps5
        $cs = Api 'GET' '/api/consoles'; $list = @(); if ($cs -is [array]) { $list = $cs } elseif ($cs.consoles) { $list = @($cs.consoles) }
        foreach ($c in $list) { if (($c | ConvertTo-Json -Compress) -match [regex]::Escape([string]$j.ps5)) {
          $a = $c.addr; if (-not $a) { $a = $c.host }; if ($a) { $script:S.ps5 = [string]$a } } }
        Log "PS5 added ($($r.action)): $($script:S.ps5)"
      }
    }
    Save-Settings; $InviteBox.Text = ''; Refresh-Rows | Out-Null; Refresh-Link
  } catch { Log "Bad invite code: $_" }
})

$BtnTest.Add_Click({
  if (-not (Refresh-Rows)) { return }
  if (-not $script:S.ps5) { Log 'No PS5 yet.'; return }
  Busy {
    $script:Hist.Clear()
    for ($i=0; $i -lt 10; $i++) { Sample; [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400 }
    $m = Show-Line; Refresh-Link
    $t = Pick-Tier $script:Path $m.rtt $m.jit
    Set-Row $LblTier (Tier-Text $t) $(if ((Tier-Index $t[0]) -le 1) { $Good } elseif ($t[0] -eq 'SMOOTH') { $Warn } else { $Bad })
    $LblTierD.Text = 'PLAY starts PS5Upload at exactly this quality.' + $(if ($script:Path -eq 'relayed') { '  Relayed link: host should enable UPnP on the router.' } else { '' })
    Log "Line: $($script:Path), $($m.rtt) ms, jitter $($m.jit) -> $($t[0])"
  }
})

# ---- play + adaptive quality
$script:Playing = $null; $script:LastLoss = $null; $script:BadWin = 0; $script:LastChange = [datetime]::MinValue
function Start-Tier($t) {
  $body = @{ host = $script:S.ps5; width = $t[1]; height = $t[2]; fps = $t[3]; bitrate_kbps = $t[4]; codec = $t[5]; wait_s = 30; keep_alive_s = 600 }
  $r = Api 'POST' '/api/ps5/rp/start' $body 45
  if ($r.ok) { $script:Playing = @{ tier = $t; session = $r.session }; $script:LastLoss = $null; $script:BadWin = 0; $script:LastChange = Get-Date
               Log "Playing at $(Tier-Text $t) (session $($r.session))"; return $true }
  $why = if ($r.code) { $r.code } elseif ($r.error) { $r.error } else { "status $($r._status)" }
  Log "Start failed: $why"
  if ($why -match 'no_credentials') { Log 'Pair first: PS5Upload > Play > Set up (one time, needs the PIN from the PS5).' }
  if ($why -match 'busy') { Log 'The PS5 is busy (another stream, or just stopped: try again in 30 s).' }
  return $false
}
$BtnPlay.Add_Click({
  if (-not (Refresh-Rows)) { Log 'Open PS5Upload first.'; return }
  if (-not $script:S.ps5) { Log 'No PS5 yet.'; return }
  Busy {
    if ($script:Hist.Count -lt 5) { for ($i=0; $i -lt 8; $i++) { Sample; Start-Sleep -Milliseconds 300 } }
    $m = Show-Line; $t = Pick-Tier $script:Path $m.rtt $m.jit
    Set-Row $LblTier (Tier-Text $t) $Good
    if (Start-Tier $t) { $e = Find-PS5Upload; if ($e) { Start-Process $e | Out-Null }; Log 'Switch to PS5Upload > Play to see and control the game.' }
  }
})
$BtnStop.Add_Click({
  if ($script:Playing) { Api 'POST' '/api/ps5/rp/stop' @{ host = $script:S.ps5; session = $script:Playing.session } | Out-Null }
  else { Api 'POST' '/api/ps5/rp/stop' @{ host = $script:S.ps5 } | Out-Null }
  $script:Playing = $null; $LblLive.Text = ''; Log 'Stopped.'
})
$ChkAuto.Add_CheckedChanged({ $script:S.auto_lower = $ChkAuto.Checked; Save-Settings })

function Watch-Stream {
  if (-not $script:Playing) { return }
  $sess = Api 'GET' '/api/ps5/rp/session' $null 5
  if (-not $sess.host) { $script:Playing = $null; $LblLive.Text = 'stream ended'; Log 'Stream ended.'; return }
  $live = Api 'GET' "/api/ps5/rp/live/status?addr=$([uri]::EscapeDataString($script:S.ps5))" $null 5
  $loss = $live.losses; $new = 0
  if ($loss -ne $null -and $script:LastLoss -ne $null) { $new = [math]::Max(0, [int]$loss - [int]$script:LastLoss) }
  if ($loss -ne $null) { $script:LastLoss = $loss }
  if ($new -gt 0) { $script:BadWin++ } else { $script:BadWin = 0 }
  $t = $script:Playing.tier
  $LblLive.Text = "LIVE  $($t[0])  losses +$new  " + $(if ($script:BadWin) { 'stutter' } else { 'smooth' })
  $LblLive.ForeColor = if ($script:BadWin) { $Warn } else { $Good }
  if ($script:BadWin -ge 2 -and $ChkAuto.Checked -and $t[0] -ne 'SAFE' -and ((Get-Date) - $script:LastChange).TotalSeconds -gt 60) {
    $m = Stats; $lower = Pick-Tier $script:Path $m.rtt $m.jit $t[0]
    Log "Stuttering -> stepping down to $(Tier-Text $lower)"; [Media.SystemSounds]::Asterisk.Play()
    Api 'POST' '/api/ps5/rp/stop' @{ host = $script:S.ps5; session = $script:Playing.session } | Out-Null
    Start-Sleep -Seconds 2
    if (-not (Start-Tier $lower)) { $script:Playing = $null }
  }
}

$BtnBoost.Add_Click({
  Busy {
    $q = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS'
    New-Item $q -Force | Out-Null; Set-ItemProperty $q -Name 'Do not use NLA' -Value '1' -Type String
    foreach ($n in 'PS5Upload.exe','ps5upload-engine.exe') {
      Remove-NetQosPolicy -Name "PS5Buddy-$n" -Confirm:$false -ErrorAction SilentlyContinue
      New-NetQosPolicy -Name "PS5Buddy-$n" -AppPathNameMatchCondition $n -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
    }
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord
    Set-ItemProperty $mm -Name SystemResponsiveness -Value 10 -Type DWord
    cmd /c "powercfg /setactive SCHEME_MIN >nul 2>nul"
    $e = Find-PS5Upload
    if ($e) { $eng = Join-Path (Split-Path $e) 'ps5upload-engine.exe'
      foreach ($p in @($e, $eng)) { if (Test-Path $p) {
        Remove-NetFirewallRule -DisplayName "PS5 Buddy $(Split-Path $p -Leaf)" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "PS5 Buddy $(Split-Path $p -Leaf)" -Direction Inbound -Program $p -Action Allow | Out-Null } } }
    $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 9 }
    $wired = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 14 }
    Log 'Speed boost on: PS5Upload traffic top priority (DSCP EF), no network throttling, high-performance power, firewall open for direct Tailscale.'
    if ($wifi -and -not $wired) { Log 'You are on Wi-Fi: an ethernet cable is the biggest lag fix on your side.' }
  }
})

# ================================================================ HOST TAB
L $TabHost 'Your PS5 runs PS5Upload''s Tailscale itself, so the stream leaves on your house upload.' 15 12 710 | Out-Null
L $TabHost '1. PS5 on Tailscale' 15 45 400 24 11 $true | Out-Null
$HostRowTs = L $TabHost 'PS5 Tailscale: ?' 15 75 560
$BtnHostCheck = B $TabHost 'Check' 585 70 140 28
L $TabHost 'Not on yet: PS5Upload > Connection > the PS5 card > Put this PS5 on Tailscale.' 15 100 710 | Out-Null

L $TabHost '2. Your upload' 15 135 400 24 11 $true | Out-Null
$HostUp = T $TabHost ([string]$script:S.upload_mbps) 15 165 100
L $TabHost 'Mbps' 120 168 50 | Out-Null
$BtnMeas = B $TabHost 'Measure' 175 162 120

L $TabHost '3. Invite your friend' 15 210 400 24 11 $true | Out-Null
$BtnMake = B $TabHost 'Copy invite code' 15 240 180
L $TabHost 'Also let them in: PS5Upload > Connection > PS5 card > Invite a device.' 205 246 520 | Out-Null

L $TabHost '4. Play Together guests (Player 2-4 from your stream)' 15 290 500 24 11 $true | Out-Null
$ChkGuests = New-Object Windows.Forms.CheckBox; $ChkGuests.Text='Watch guests'; $ChkGuests.Location='15,320'
$ChkGuests.ForeColor=$Fg; $ChkGuests.Size='150,24'; $TabHost.Controls.Add($ChkGuests)
$HostGuests = L $TabHost '' 15 350 710 120

$BtnHostCheck.Add_Click({
  if (-not (Refresh-Rows)) { Set-Row $HostRowTs 'Open PS5Upload first (Play tab)' $Bad; return }
  if (-not $script:S.ps5) { Set-Row $HostRowTs 'Add your PS5 in PS5Upload first' $Warn; return }
  Busy {
    $r = Api 'GET' "/api/ps5/tailnet?addr=$([uri]::EscapeDataString($script:S.ps5))" $null 15
    $ip = $r.ip; $name = if ($r.name) { $r.name } else { $r.hostname }; $st = $r.state
    if ($ip) { Set-Row $HostRowTs "PS5 Tailscale: on as $name ($ip), state $st" $Good }
    elseif ($r.error) { Set-Row $HostRowTs "PS5 Tailscale: $($r.error)" $Warn }
    else { Set-Row $HostRowTs "PS5 Tailscale: off ($st)" $Warn }
    Refresh-Link; Log $RowLink.Text
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
      $mbps = [math]::Round(25000000*8/1e6 / $sw.Elapsed.TotalSeconds, 1); if ($mbps -lt $best) { $best = $mbps }
    }
    $HostUp.Text = [string]$best; $script:S.upload_mbps = $best; Save-Settings; Log "Upload: $best Mbps (the PS5 uses this same line)"
  }
})

$BtnMake.Add_Click({
  if (-not $script:S.ps5) { Log 'Add your PS5 in PS5Upload first.'; return }
  $target = $script:S.ps5
  $r = Api 'GET' "/api/ps5/tailnet?addr=$([uri]::EscapeDataString($script:S.ps5))" $null 15
  if ($r.ip) { $target = [string]$r.ip } elseif ($r.name) { $target = [string]$r.name }
  else { Log 'Note: PS5 Tailscale not confirmed - friend may not reach it until it is on.' }
  $up = 0; [void][double]::TryParse($HostUp.Text, [ref]$up)
  $code = 'PS5B2:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ v = 2; ps5 = $target; up = $up } | ConvertTo-Json -Compress)))
  [Windows.Forms.Clipboard]::SetText($code); Log "Invite code copied ($target, $up Mbps). Send it to your friend."
})

function Watch-Guests {
  $j = Api 'GET' "/api/join?addr=$([uri]::EscapeDataString($script:S.ps5))" $null 5
  if (-not $j.open) { $HostGuests.Text = 'Play Together is not open (start Play in PS5Upload, then open Play Together).'; return }
  $lines = @()
  foreach ($g in @($j.guests)) {
    $rt = $g.rtt_ms; $tag = if ($rt -eq $null) { '' } elseif ($rt -le 40) { 'smooth' } elseif ($rt -le 80) { 'ok' } else { 'laggy - lower bitrate in PS5Upload ("Lower to")' }
    $lines += "$($g.name)  ping $rt ms  $tag"
  }
  $HostGuests.Text = if ($lines.Count) { $lines -join "`r`n" } else { 'No guests yet.' }
}

# ---------------------------------------------------------------- timer
$Timer = New-Object Windows.Forms.Timer; $Timer.Interval = 2000; $script:Tick = 0
$Timer.Add_Tick({
  $script:Tick++
  if ($Tabs.SelectedTab -eq $TabPlay -and $script:S.ps5 -and ($script:Tick % 2 -eq 0)) { Sample; Show-Line | Out-Null }
  if ($script:Playing -and ($script:Tick % 5 -eq 0)) { Watch-Stream }
  if ($Tabs.SelectedTab -eq $TabHost -and $ChkGuests.Checked -and ($script:Tick % 2 -eq 0)) { Watch-Guests }
  if ($script:Tick % 15 -eq 0) { Refresh-Rows | Out-Null }
})
$Form.Add_Shown({
  if (-not (Engine-Up)) { $e = Find-PS5Upload; if ($e) { Start-Process $e | Out-Null; Log 'Starting PS5Upload...' } }
  for ($i=0; $i -lt 20 -and -not (Engine-Up); $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500 }
  Refresh-Rows | Out-Null; Refresh-Link
  Log 'PS5 Buddy 2 ready. Friend: Turn on Tailscale > Use invite > Test line > PLAY. Host: Host tab.'
  $Timer.Start()
})
$Form.Add_FormClosed({ $Timer.Stop() })
[void]$Form.ShowDialog()

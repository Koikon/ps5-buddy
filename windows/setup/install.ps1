# PS5 Buddy installer (friend side, Windows 10/11)
# Installs Tailscale + chiaki-ng, joins the host's tailnet, adds a "PS5 Buddy" desktop shortcut.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir  = Join-Path $env:LOCALAPPDATA 'PS5Buddy'
$tsExe   = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null

function Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Read-Ini($path) {
  $h = @{}
  foreach ($line in Get-Content $path) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $h[$matches[1]] = $matches[2] }
  }
  return $h
}
$cfg = Read-Ini (Join-Path $here 'buddy.ini')

Write-Host '=====================================' -ForegroundColor Magenta
Write-Host '   PS5 Buddy - low-lag Remote Play   ' -ForegroundColor Magenta
Write-Host '=====================================' -ForegroundColor Magenta

# ---------- 1. Tailscale ----------
Step 'Installing Tailscale'
if (Test-Path $tsExe) {
  Ok 'Tailscale already installed.'
} else {
  $done = $false
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    try {
      winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
      if (Test-Path $tsExe) { $done = $true }
    } catch { Warn 'winget failed, downloading directly instead.' }
  }
  if (-not $done) {
    $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
    Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
  }
  if (-not (Test-Path $tsExe)) { throw 'Tailscale did not install. Install it from tailscale.com/download and run this again.' }
  Ok 'Tailscale installed.'
}
Start-Service Tailscale -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# ---------- 2. chiaki-ng (Remote Play client) ----------
Step 'Installing chiaki-ng (PS5 Remote Play app)'
$chiakiDir = Join-Path $appDir 'chiaki-ng'
$chiakiExe = Get-ChildItem $chiakiDir -Recurse -Include 'chiaki-ng.exe','chiaki.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($chiakiExe) {
  Ok 'chiaki-ng already installed.'
} else {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/streetpea/chiaki-ng/releases/latest' -Headers @{ 'User-Agent' = 'ps5-buddy' }
  $zip = $rel.assets | Where-Object { $_.name -match '(?i)win' -and $_.name -match '(?i)\.zip$' } | Select-Object -First 1
  if ($zip) {
    $zipPath = Join-Path $env:TEMP $zip.name
    Write-Host "    Downloading $($zip.name) ($($rel.tag_name))"
    Invoke-WebRequest $zip.browser_download_url -OutFile $zipPath
    if (Test-Path $chiakiDir) { Remove-Item $chiakiDir -Recurse -Force }
    Expand-Archive $zipPath -DestinationPath $chiakiDir -Force
    $chiakiExe = Get-ChildItem $chiakiDir -Recurse -Include 'chiaki-ng.exe','chiaki.exe' | Select-Object -First 1
  } else {
    $inst = $rel.assets | Where-Object { $_.name -match '(?i)win' -and $_.name -match '(?i)\.exe$' } | Select-Object -First 1
    if (-not $inst) { throw 'Could not find a Windows build of chiaki-ng. Get it from github.com/streetpea/chiaki-ng/releases' }
    $instPath = Join-Path $env:TEMP $inst.name
    Invoke-WebRequest $inst.browser_download_url -OutFile $instPath
    Warn 'Running the chiaki-ng installer - click through it.'
    Start-Process $instPath -Wait
    $chiakiExe = Get-ChildItem "$env:ProgramFiles","${env:ProgramFiles(x86)}","$env:LOCALAPPDATA\Programs" -Recurse -Include 'chiaki-ng.exe','chiaki.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if (-not $chiakiExe) { throw 'chiaki-ng did not install.' }
  Ok "chiaki-ng installed: $($chiakiExe.FullName)"
}
Set-Content (Join-Path $appDir 'chiaki-path.txt') $chiakiExe.FullName

# ---------- 3. Join the host's tailnet ----------
Step 'Connecting to the host''s private network'
$ver = & $tsExe status --json | Out-String
$state = ''
try { $state = ($ver | ConvertFrom-Json).BackendState } catch {}
if ($state -eq 'Running') {
  & $tsExe set --accept-routes=true --unattended=true | Out-Null
  Ok 'Already connected - turned on PS5 route.'
} elseif ($cfg['AUTHKEY']) {
  & $tsExe up --accept-routes --unattended "--hostname=ps5-buddy-$($env:COMPUTERNAME.ToLower())" "--authkey=$($cfg['AUTHKEY'])" | Out-Host
  Ok 'Joined with the host''s invite key.'
} else {
  Warn 'A browser window will open - log in with the account the host invited.'
  $log  = Join-Path $env:TEMP 'ps5buddy-up.err.log'
  $log2 = Join-Path $env:TEMP 'ps5buddy-up.out.log'
  Remove-Item $log,$log2 -ErrorAction SilentlyContinue
  $p = Start-Process $tsExe -ArgumentList 'up','--accept-routes','--unattended' -RedirectStandardError $log -RedirectStandardOutput $log2 -PassThru -WindowStyle Hidden
  $opened = $false
  while (-not $p.HasExited) {
    Start-Sleep -Milliseconds 500
    if (-not $opened) {
      $m = Select-String -Path $log,$log2 -Pattern 'https://login\.tailscale\.com/\S+' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($m) { Start-Process $m.Matches[0].Value; $opened = $true }
    }
  }
}
Start-Sleep -Seconds 2
$st = & $tsExe status --json | ConvertFrom-Json
if ($st.BackendState -ne 'Running') { throw 'Tailscale is not connected. Run Install.bat again.' }
Ok "Connected as $($st.Self.HostName) ($($st.Self.TailscaleIPs[0]))"

# ---------- 4. Low-lag Windows tweaks (all safe, all reversible) ----------
Step 'Applying low-lag network tweaks'
# Keep Windows from throttling network for media/background
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord
Set-ItemProperty $mm -Name SystemResponsiveness -Value 10 -Type DWord
# High-priority QoS tag on chiaki-ng's traffic (helps on routers that honor DSCP)
Remove-NetQosPolicy -Name 'PS5Buddy' -Confirm:$false -ErrorAction SilentlyContinue
New-NetQosPolicy -Name 'PS5Buddy' -AppPathNameMatchCondition (Split-Path $chiakiExe.FullName -Leaf) -DSCPAction 46 -NetworkProfile All | Out-Null
# Let chiaki-ng through the firewall (stream comes back as UDP)
Remove-NetFirewallRule -DisplayName 'PS5 Buddy chiaki-ng' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'PS5 Buddy chiaki-ng' -Direction Inbound -Program $chiakiExe.FullName -Action Allow | Out-Null
# Prefer the High performance power plan while plugged in (stops CPU/NIC napping)
cmd /c "powercfg /setactive SCHEME_MIN >nul 2>nul"
Ok 'Done (network throttling off, traffic priority, firewall rule, high-performance power).'

# ---------- 5. App + shortcuts ----------
Step 'Installing the PS5 Buddy app'
foreach ($f in 'gui.ps1','play.ps1','buddy.ini','uninstall.ps1') { Copy-Item (Join-Path $here $f) $appDir -Force }
# elevating uninstaller for Settings > Apps
Set-Content (Join-Path $appDir 'uninstall.cmd') -Encoding Ascii -Value @(
  '@echo off', 'net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs" & exit /b)',
  'copy /y "%~dp0uninstall.ps1" "%TEMP%\ps5buddy-uninstall.ps1" >nul',
  'powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\ps5buddy-uninstall.ps1"', 'pause')
function New-AdminShortcut($path) {
  $ws = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut($path)
  $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$appDir\gui.ps1`""
  $lnk.IconLocation = $chiakiExe.FullName
  $lnk.WorkingDirectory = $appDir
  $lnk.Description = 'PS5 Buddy - low-lag PS5 Remote Play over Tailscale'
  $lnk.Save()
  # flag the shortcut "Run as administrator" (byte 0x15, bit 0x20) - needed for Tailscale + QoS
  $b = [IO.File]::ReadAllBytes($path); $b[0x15] = $b[0x15] -bor 0x20; [IO.File]::WriteAllBytes($path, $b)
}
New-AdminShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PS5 Buddy.lnk')
New-AdminShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'PS5 Buddy.lnk')
# show up in Settings > Apps so it can be uninstalled normally
$u = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PS5Buddy'
New-Item $u -Force | Out-Null
Set-ItemProperty $u -Name DisplayName -Value 'PS5 Buddy'
Set-ItemProperty $u -Name DisplayVersion -Value '1.0.0'
Set-ItemProperty $u -Name Publisher -Value 'PS5 Buddy'
Set-ItemProperty $u -Name DisplayIcon -Value $chiakiExe.FullName
Set-ItemProperty $u -Name UninstallString -Value "`"$appDir\uninstall.cmd`""
Ok 'App installed (desktop + Start menu).'

Write-Host ''
Write-Host 'All set! Opening PS5 Buddy...' -ForegroundColor Green
Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$appDir\gui.ps1`""

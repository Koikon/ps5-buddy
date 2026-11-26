# PS5 Buddy 2 installer (Windows 10/11)
# Installs PS5Upload (it has Tailscale built in, nothing else needed) + the PS5 Buddy app.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Join-Path $env:LOCALAPPDATA 'PS5Buddy'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
function Step($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

Write-Host '========================================' -ForegroundColor Magenta
Write-Host '  PS5 Buddy 2 - PS5Upload + Tailscale   ' -ForegroundColor Magenta
Write-Host '========================================' -ForegroundColor Magenta

function Find-PS5Upload {
  Get-ChildItem "$env:LOCALAPPDATA\PS5Upload","$env:LOCALAPPDATA\Programs","$env:ProgramFiles\PS5Upload","$appDir\PS5Upload" `
    -Recurse -Filter 'PS5Upload.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
}

# ---------- 1. PS5Upload ----------
Step 'Installing PS5Upload (with built-in Tailscale)'
$exe = Find-PS5Upload
if ($exe) { Ok "Already installed: $($exe.FullName)" }
else {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/phantomptr/ps5upload/releases/latest' -Headers @{ 'User-Agent' = 'ps5-buddy' }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  $setup = $rel.assets | Where-Object { $_.name -match "win-$arch-setup\.exe$" } | Select-Object -First 1
  $zip   = $rel.assets | Where-Object { $_.name -match "win-$arch\.zip$" } | Select-Object -First 1
  if ($setup) {
    $p = Join-Path $env:TEMP $setup.name
    Write-Host "    Downloading $($setup.name) ($($rel.tag_name))"
    Invoke-WebRequest $setup.browser_download_url -OutFile $p
    Start-Process $p -ArgumentList '/S' -Wait
    $exe = Find-PS5Upload
  }
  if (-not $exe -and $zip) {
    Warn 'Installer did not finish quietly - using the portable version.'
    $p = Join-Path $env:TEMP $zip.name
    Invoke-WebRequest $zip.browser_download_url -OutFile $p
    Expand-Archive $p -DestinationPath (Join-Path $appDir 'PS5Upload') -Force
    $exe = Find-PS5Upload
  }
  if (-not $exe) { throw 'PS5Upload did not install. Get it from github.com/phantomptr/ps5upload/releases and run this again.' }
  Unblock-File $exe.FullName -ErrorAction SilentlyContinue
  Ok "PS5Upload installed: $($exe.FullName)"
}

# ---------- 2. PS5 Buddy app ----------
Step 'Installing PS5 Buddy'
foreach ($f in 'gui.ps1','uninstall.ps1') { Copy-Item (Join-Path $here $f) $appDir -Force }
@{ ps5=''; upload_mbps=0; ps5upload_exe=$exe.FullName; auto_lower=$true } | ConvertTo-Json | Set-Content (Join-Path $appDir 'settings.json')
Set-Content (Join-Path $appDir 'uninstall.cmd') -Encoding Ascii -Value @(
  '@echo off', 'net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs" & exit /b)',
  'copy /y "%~dp0uninstall.ps1" "%TEMP%\ps5buddy-uninstall.ps1" >nul',
  'powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\ps5buddy-uninstall.ps1"', 'pause')
function New-AdminShortcut($path) {
  $ws = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut($path)
  $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$appDir\gui.ps1`""
  $lnk.IconLocation = $exe.FullName
  $lnk.WorkingDirectory = $appDir
  $lnk.Description = 'PS5 Buddy - low-lag PS5Upload Play over Tailscale'
  $lnk.Save()
  # "Run as administrator" flag (byte 0x15, bit 0x20): Speed boost needs it
  $b = [IO.File]::ReadAllBytes($path); $b[0x15] = $b[0x15] -bor 0x20; [IO.File]::WriteAllBytes($path, $b)
}
New-AdminShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PS5 Buddy.lnk')
New-AdminShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'PS5 Buddy.lnk')
$u = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PS5Buddy'
New-Item $u -Force | Out-Null
Set-ItemProperty $u -Name DisplayName -Value 'PS5 Buddy'
$ver = '0'; $m = Select-String -Path (Join-Path $here 'gui.ps1') -Pattern '^\$Version = ''([\d.]+)''' | Select-Object -First 1
if ($m) { $ver = $m.Matches[0].Groups[1].Value }
Set-ItemProperty $u -Name DisplayVersion -Value $ver
Set-ItemProperty $u -Name Publisher -Value 'PS5 Buddy'
Set-ItemProperty $u -Name DisplayIcon -Value $exe.FullName
Set-ItemProperty $u -Name UninstallString -Value "`"$appDir\uninstall.cmd`""
Ok 'Desktop + Start menu shortcuts made.'

Write-Host ''
Write-Host 'All set! Opening PS5 Buddy (it starts PS5Upload too)...' -ForegroundColor Green
Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$appDir\gui.ps1`""

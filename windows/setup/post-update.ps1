# One-time step the updater runs after copying new files (2.2.0).
# Older updaters only copy gui.ps1 + uninstall.ps1, so bring boost.ps1 along here, and
# replace the old "always run as admin" shortcuts with normal ones (only Speed boost asks now).
param([string]$AppDir = '')
if (-not $AppDir) { $AppDir = Join-Path $env:LOCALAPPDATA 'PS5Buddy' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in 'boost.ps1','gui.ps1','uninstall.ps1') {
  $src = Join-Path $here $f; if (Test-Path $src) { Copy-Item $src $AppDir -Force }
}
$icon = ''
try { $s = Get-Content (Join-Path $AppDir 'settings.json') -Raw | ConvertFrom-Json; if ($s.ps5upload_exe) { $icon = $s.ps5upload_exe } } catch {}
$ws = New-Object -ComObject WScript.Shell
foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
  $path = Join-Path $dir 'PS5 Buddy.lnk'
  if (-not (Test-Path $path)) { continue }
  Remove-Item $path -Force
  $lnk = $ws.CreateShortcut($path)
  $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AppDir\gui.ps1`""
  if ($icon) { $lnk.IconLocation = $icon }
  $lnk.WorkingDirectory = $AppDir
  $lnk.Description = 'PS5 Buddy - low-lag PS5Upload Play over Tailscale'
  $lnk.Save()
}
$u = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PS5Buddy'
if (Test-Path $u) {
  Set-ItemProperty $u -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"Copy-Item '$AppDir\uninstall.ps1' `$env:TEMP\ps5buddy-uninstall.ps1 -Force; & `$env:TEMP\ps5buddy-uninstall.ps1 -AppDir '$AppDir'`""
}
Remove-Item (Join-Path $AppDir 'uninstall.cmd') -ErrorAction SilentlyContinue

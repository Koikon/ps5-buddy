# PS5 Buddy uninstall: removes the app, shortcuts and (if applied) the speed boost.
# PS5Upload is left installed.
param([string]$AppDir = '')
if (-not $AppDir) { $AppDir = Join-Path $env:LOCALAPPDATA 'PS5Buddy' }
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PS5 Buddy.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'PS5 Buddy.lnk') -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PS5Buddy' -Recurse -ErrorAction SilentlyContinue
$boost = Join-Path $AppDir 'boost.ps1'
if ((Test-Path (Join-Path $AppDir 'boost-applied')) -and (Test-Path $boost)) {
  Write-Host 'Undoing the speed boost (click Yes on the Windows prompt)...'
  $tmp = Join-Path $env:TEMP 'ps5buddy-boost.ps1'; Copy-Item $boost $tmp -Force
  try { Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -WindowStyle Hidden `
          -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tmp`"",'-Undo' }
  catch { Write-Host 'Skipped (no admin permission) - Windows network settings stay boosted.' -ForegroundColor Yellow }
}
Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'PS5 Buddy removed. PS5Upload is still installed: remove it from Settings > Apps if you want.' -ForegroundColor Green

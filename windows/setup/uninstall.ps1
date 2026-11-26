# PS5 Buddy uninstall: removes the app, shortcuts and tweaks. PS5Upload is left installed.
$appDir = Join-Path $env:LOCALAPPDATA 'PS5Buddy'
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PS5 Buddy.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'PS5 Buddy.lnk') -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PS5Buddy' -Recurse -ErrorAction SilentlyContinue
foreach ($n in 'PS5Upload.exe','ps5upload-engine.exe') {
  Remove-NetQosPolicy -Name "PS5Buddy-$n" -Confirm:$false -ErrorAction SilentlyContinue
  Remove-NetFirewallRule -DisplayName "PS5 Buddy $n" -ErrorAction SilentlyContinue
}
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 10 -Type DWord
Set-ItemProperty $mm -Name SystemResponsiveness -Value 20 -Type DWord
cmd /c "powercfg /setactive SCHEME_BALANCED >nul 2>nul"
Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'PS5 Buddy removed (Windows defaults restored). PS5Upload is still installed:' -ForegroundColor Green
Write-Host 'remove it from Settings > Apps if you want.'

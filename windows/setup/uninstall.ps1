# PS5 Buddy uninstall: removes shortcut, tweaks, chiaki-ng copy; offers to remove Tailscale
$appDir = Join-Path $env:LOCALAPPDATA 'PS5Buddy'
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PS5 Buddy.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'PS5 Buddy.lnk') -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PS5Buddy' -Recurse -ErrorAction SilentlyContinue
Remove-NetQosPolicy -Name 'PS5Buddy-ts' -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'PS5 Buddy route' -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'PS5 Buddy tailscale direct' -ErrorAction SilentlyContinue
Remove-NetQosPolicy -Name 'PS5Buddy' -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'PS5 Buddy chiaki-ng' -ErrorAction SilentlyContinue
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 10 -Type DWord
Set-ItemProperty $mm -Name SystemResponsiveness -Value 20 -Type DWord
cmd /c "powercfg /setactive SCHEME_BALANCED >nul 2>nul"
Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'PS5 Buddy removed (Windows defaults restored).' -ForegroundColor Green
$a = Read-Host 'Also log out of the host network and uninstall Tailscale? (y/N)'
if ($a -match '^[yY]') {
  & "$env:ProgramFiles\Tailscale\tailscale.exe" logout
  if (Get-Command winget -ErrorAction SilentlyContinue) { winget uninstall --id Tailscale.Tailscale -e --silent }
  else { Write-Host 'Uninstall Tailscale from Settings > Apps.' }
}

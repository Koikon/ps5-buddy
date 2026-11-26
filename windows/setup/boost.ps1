# PS5 Buddy speed boost (runs elevated, started by the app's Speed boost button)
#   boost.ps1 -Exe <path to PS5Upload.exe>   apply
#   boost.ps1 -Undo                          restore Windows defaults
param([string]$Exe = '', [switch]$Undo)
$ErrorActionPreference = 'Continue'
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$names = 'PS5Upload.exe','ps5upload-engine.exe'
try {
  foreach ($n in $names) {
    Remove-NetQosPolicy -Name "PS5Buddy-$n" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "PS5 Buddy $n" -ErrorAction SilentlyContinue
  }
  if ($Undo) {
    Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 10 -Type DWord
    Set-ItemProperty $mm -Name SystemResponsiveness -Value 20 -Type DWord
    cmd /c "powercfg /setactive SCHEME_BALANCED >nul 2>nul"
    exit 0
  }
  # top priority (DSCP 46 / EF) for PS5Upload's traffic
  $q = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS'
  New-Item $q -Force | Out-Null; Set-ItemProperty $q -Name 'Do not use NLA' -Value '1' -Type String
  foreach ($n in $names) {
    New-NetQosPolicy -Name "PS5Buddy-$n" -AppPathNameMatchCondition $n -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
  }
  # no Windows network throttling, high-performance power plan
  Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord
  Set-ItemProperty $mm -Name SystemResponsiveness -Value 10 -Type DWord
  cmd /c "powercfg /setactive SCHEME_MIN >nul 2>nul"
  # firewall: let direct Tailscale (UDP) in to PS5Upload and its engine
  if ($Exe -and (Test-Path $Exe)) {
    foreach ($p in @($Exe, (Join-Path (Split-Path $Exe) 'ps5upload-engine.exe'))) {
      if (Test-Path $p) { New-NetFirewallRule -DisplayName "PS5 Buddy $(Split-Path $p -Leaf)" -Direction Inbound -Program $p -Action Allow | Out-Null }
    }
  }
  exit 0
} catch { exit 1 }

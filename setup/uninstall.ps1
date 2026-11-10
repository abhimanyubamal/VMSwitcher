#requires -Version 5.1
# Called by the uninstaller (and before an upgrade): stop the service, the tray app and any open VM Switcher windows.
param([switch]$KeepService)
$ErrorActionPreference = 'Continue'
$ServiceName = 'VMSwitcherWatchdog'

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue }
    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    if (-not $KeepService) { & sc.exe delete $ServiceName | Out-Null }
}
if (-not $KeepService) {
    Unregister-ScheduledTask -TaskName 'VM Switcher Tray' -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetFirewallRule -Group 'VM Switcher' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# Close the windowed app and terminal (they run as powershell.exe with our scripts).
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'VMSwitcher\\app\\(Gui|Terminal|Watchdog)\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name VMSwitcher, VMSwitcherTerminal, VMSwitcherService -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not $KeepService) {
    try { Write-EventLog -LogName Application -Source 'VMSwitcher' -EventId 2000 -EntryType Warning -Message 'VM Switcher was uninstalled. Automatic failover is OFF.' } catch { }
}
exit 0

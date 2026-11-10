#requires -Version 5.1
<#
  VM Switcher watchdog. Runs as the Windows service "VMSwitcherWatchdog" (via VMSwitcherService.exe),
  or by hand for testing:  powershell -File Watchdog.ps1 [-MaxTicks 10]
  Every CheckIntervalSeconds (3 s) it checks both VMs, logs changes, and fails over / fails back.
#>
param([int]$MaxTicks = 0)

$ErrorActionPreference = 'Stop'

# If the script dies before it can log normally, leave a note where an admin will find it.
trap {
    try {
        $dir = if ($env:VMSWITCHER_HOME) { Join-Path $env:VMSWITCHER_HOME 'logs' } else { Join-Path $env:ProgramData 'VMSwitcher\logs' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Add-Content -Path (Join-Path $dir 'watchdog-crash.log') -Value ("{0}  {1}`r`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message, $_.ScriptStackTrace)
    } catch { }
    break
}

$ModulePath = Join-Path $PSScriptRoot 'VMSwitcher.Core.psm1'
Import-Module $ModulePath -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'PeerServer.ps1')
$suffix = Get-VmsInstanceSuffix

# Only one watchdog may run at a time. (Access denied = the SYSTEM service already owns it.)
try { $single = New-Object System.Threading.Mutex($false, ('Global\VMSwitcher.Watchdog' + $suffix)) }
catch { Write-Output 'The VM Switcher watchdog service is already running. Exiting.'; exit 0 }
try { $owned = $single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Write-Output 'Another VM Switcher watchdog is already running. Exiting.'; exit 0 }

# The service host sets this event to ask for a clean stop. Waiting on it only needs Synchronize rights.
$stopName = 'Global\VMSwitcherWatchdogStop' + $suffix
try {
    $stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $stopName)
} catch {
    $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting($stopName, [System.Security.AccessControl.EventWaitHandleRights]::Synchronize)
}

Initialize-Vms -Source 'Watchdog'
$cfg = Get-VmsConfig
$started = Get-Date
$row = Get-VmsWatchdogRow
$state = if ($row) { $row.State } else { New-VmsWatchdogState }
$previous = @{}

$localRole = Get-VmsLocalRole -Refresh
$intro = "Watchdog started on $env:COMPUTERNAME, which holds the $($localRole.ToUpper()). It checks both VMs every $($cfg.CheckIntervalSeconds) s (Hyper-V heartbeat; the other server by one ping and by asking its VM Switcher) and fails over after $($cfg.MissedPingsForFailover) missed checks or an unexpected stop."
if ($state.Mode -eq 'FailedOver') { $intro += ' It remembers an active failover and continues it.' }
Write-VmsEvent -Action 'WatchdogStart' -Message $intro
if ($localRole -eq 'None') {
    Write-VmsEvent -Severity Critical -Action 'RoleUnknown' -Message "Neither '$($cfg.Primary.Name)' nor '$($cfg.Secondary.Name)' exists in Hyper-V on this server, and its IP addresses match neither $($cfg.Primary.Host) nor $($cfg.Secondary.Host). Check the settings." -Alert -Title 'This server holds neither VM'
}

# Peer endpoint: lets VM Switcher on the other server see and control this server's VM.
$peerServer = $null
if (Get-VmsRemoteRole) {
    $peerServer = Start-VmsPeerServer -ModulePath $ModulePath -Port ([int]$cfg.ListenPort)
    if ($peerServer.Sync.Error) {
        Write-VmsEvent -Severity Critical -Action 'PeerListen' -Result 'FAILED' -Message "Cannot listen on TCP port $($cfg.ListenPort) for the other server: $($peerServer.Sync.Error). The other server cannot see this VM until this is fixed." -Alert -Title 'Peer port problem'
    } else {
        Write-VmsEvent -Action 'PeerListen' -Message "Listening on TCP port $($cfg.ListenPort) for VM Switcher on $(Get-VmsPeerAddress)."
    }
}

$interval = [int]$cfg.CheckIntervalSeconds * 1000
$tick = 0
$lastPrune = [datetime]::MinValue
$consecutiveErrors = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
$next = 0

try {
    while ($true) {
        $tick++
        try {
            $result = Invoke-VmsWatchdogTick -State $state -Previous $previous -Now (Get-Date) -Started $started
            $state = $result.State
            $consecutiveErrors = 0
        } catch {
            $consecutiveErrors++
            # Log the first error and then every 100th, so a long outage does not flood the log.
            if ($consecutiveErrors -eq 1 -or $consecutiveErrors % 100 -eq 0) {
                try { Write-VmsEvent -Severity Warning -Action 'WatchdogError' -Message "The watchdog had a problem checking the VMs and will keep trying: $($_.Exception.Message)" -Detail $_.ScriptStackTrace } catch { }
            }
        }

        if (((Get-Date) - $lastPrune).TotalHours -ge 6) {
            $lastPrune = Get-Date
            try {
                $keep = (Get-Date).AddDays(-[int]$cfg.LogRetentionDays)
                Get-ChildItem (Join-Path (Get-VmsHome) 'logs') -Filter 'VMSwitcher-*.log' | Where-Object { $_.LastWriteTime -lt $keep } | Remove-Item -Force
                [void](Get-VmsDb).Execute('DELETE FROM alerts WHERE ts < ?', @((Format-VmsTs ((Get-Date).AddDays(-7)))))
            } catch { }
        }

        if ($MaxTicks -gt 0 -and $tick -ge $MaxTicks) { break }

        # Fixed cadence: the next check starts exactly one interval after the previous one started.
        # Every 1 s while the Secondary is ON or a failover/failback is active, so a returning Primary is held within seconds.
        $fast = ($state.Mode -ne 'Normal') -or ($result -and $result.Snapshot.Secondary.IsUp)
        $next += $(if ($fast) { [int]$cfg.FastCheckIntervalSeconds * 1000 } else { $interval })
        $wait = $next - $clock.ElapsedMilliseconds
        if ($wait -lt 0) { $next = $clock.ElapsedMilliseconds; $wait = 0 }
        if ($stopEvent.WaitOne([int]$wait)) { break }
    }
} finally {
    try { Write-VmsEvent -Action 'WatchdogStop' -Message 'Watchdog stopped. Automatic failover is OFF until it runs again.' -Severity Warning } catch { }
    Stop-VmsPeerServer $peerServer
    Close-Vms
    $single.ReleaseMutex()
}

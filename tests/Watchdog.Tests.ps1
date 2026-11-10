# Pester 3.4 (built into Windows) tests for the failover brain + executor, using the simulated Hyper-V provider.
# Run:  Invoke-Pester D:\VMSwitcher\tests
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\VMSwitcher.Core.psm1'

function Reset-World {
    $script:homeDir = Join-Path $env:TEMP ('vmswitcher-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $env:VMSWITCHER_HOME = $script:homeDir
    $env:VMSWITCHER_PROVIDER = 'Simulated'
    Import-Module $modulePath -Force -DisableNameChecking
    Initialize-Vms -Source 'Test'
    $sim = Read-VmsSim; $sim.BootSeconds = 0; $sim.StopSeconds = 0; Write-VmsSim $sim
    Set-VmsSimVm -Role Primary -State Running -PingOk $true -UptimeSeconds 9999
    Set-VmsSimVm -Role Secondary -State Off
    $script:state = New-VmsWatchdogState
    $script:prev = @{}
    $script:now = Get-Date
}

function Step([int]$Count = 1) {
    for ($i = 0; $i -lt $Count; $i++) {
        $script:now = $script:now.AddSeconds(3)
        $r = Invoke-VmsWatchdogTick -State $script:state -Previous $script:prev -Now $script:now
        $script:state = $r.State
    }
    return $r
}

function SecondaryState { (Get-VmsProviderVm (Get-VmsVmConfig Secondary).Name).State }
function PrimaryState { (Get-VmsProviderVm (Get-VmsVmConfig Primary).Name).State }
function Count([string]$sql) { [int](Get-VmsDb).Scalar($sql) }

Describe 'Watchdog failover brain' {
    BeforeEach { Reset-World }
    AfterEach { Close-Vms; Remove-Item $script:homeDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'does nothing while the Primary is healthy' {
        Step 5 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        SecondaryState | Should Be 'Off'
        Count 'SELECT COUNT(*) FROM handoffs' | Should Be 0
    }

    It 'fails over on the very next tick when the Primary turns OFF unexpectedly' {
        Step 1 | Out-Null
        Set-VmsSimVm -Role Primary -State Off
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'FailedOver'
        SecondaryState | Should Be 'Running'
        Count "SELECT COUNT(*) FROM handoffs WHERE status='Open' AND trigger='Automatic'" | Should Be 1
        Count "SELECT COUNT(*) FROM alerts WHERE title LIKE 'Failover%'" | Should Be 1
        (Get-VmsDb).Scalar("SELECT message FROM events WHERE action='Failover'") | Should Match 'turned OFF unexpectedly'
    }

    It 'tolerates 2 missed pings and fails over on the 3rd (about 9 s)' {
        Set-VmsSimVm -Role Primary -PingOk $false
        Step 2 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        $script:state.Misses | Should Be 2
        SecondaryState | Should Be 'Off'
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'FailedOver'
        SecondaryState | Should Be 'Running'
        $down = ConvertFrom-VmsTs ((Get-VmsDb).Scalar('SELECT primary_down_ts FROM handoffs'))
        $nowSec = ConvertFrom-VmsTs (Format-VmsTs $script:now)
        [int]($nowSec - $down).TotalSeconds | Should Be 6   # first missed ping, 2 intervals earlier
    }

    It 'resets the miss counter when a ping succeeds again' {
        Set-VmsSimVm -Role Primary -PingOk $false
        Step 2 | Out-Null
        Set-VmsSimVm -Role Primary -PingOk $true
        Step 1 | Out-Null
        $script:state.Misses | Should Be 0
        Set-VmsSimVm -Role Primary -PingOk $false
        Step 2 | Out-Null
        $script:state.Mode | Should Be 'Normal'
    }

    It 'does not fail over after a planned stop from the menu (option 4)' {
        $r = Invoke-VmsAction -Id PlannedStopPrimary
        $r.Result | Should Be 'OK'
        Step 3 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        SecondaryState | Should Be 'Off'
        Count "SELECT COUNT(*) FROM alerts WHERE title = 'Both VMs are OFF'" | Should Be 1
    }

    It 'planned switchover stops the Primary BEFORE starting the Secondary (shared IP), then fails back' {
        $r = Invoke-VmsAction -Id PlannedStopPrimary -SwitchoverFirst
        $r.Result | Should Be 'OK'
        PrimaryState | Should Be 'Off'
        SecondaryState | Should Be 'Running'
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'FailedOver'
        $r1 = Invoke-VmsAction -Id StartPrimary
        $r1.Result | Should Be 'OK'
        $r1.Message | Should Match 'shut down cleanly first'
        SecondaryState | Should Be 'Off'
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        Count "SELECT COUNT(*) FROM handoffs WHERE status='Closed' AND trigger='Planned'" | Should Be 1
    }

    It 'only watches in maintenance mode and warns once' {
        (Invoke-VmsAction -Id SetMaintenance -On $true).Result | Should Be 'OK'
        Set-VmsSimVm -Role Primary -State Off
        Step 4 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        SecondaryState | Should Be 'Off'
        Count "SELECT COUNT(*) FROM events WHERE action='MaintenanceHold'" | Should Be 1
        (Invoke-VmsAction -Id SetMaintenance -On $false).Result | Should Be 'OK'
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'FailedOver'
        SecondaryState | Should Be 'Running'
    }

    It 'records the hand-off gap, then holds the booting Primary paused while the Secondary shuts down cleanly' {
        Set-VmsSimVm -Role Primary -State Off
        Step 1 | Out-Null
        Step 1 | Out-Null                                   # Secondary answers -> gap recorded
        (Get-VmsDb).Scalar('SELECT gap_seconds FROM handoffs') | Should Be 3
        $sim = Read-VmsSim; $sim.StopSeconds = 2; Write-VmsSim $sim     # a clean shutdown takes a little time
        # Primary started outside VM Switcher (Hyper-V auto-start / Hyper-V Manager), still booting:
        Set-VmsSimVm -Role Primary -State Running -PingOk $false -UptimeSeconds 5
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'FailingBack'
        PrimaryState | Should Be 'Paused'                   # held: cannot use the shared IP address yet
        SecondaryState | Should Be 'Stopping'               # clean shutdown, data saved
        Start-Sleep -Seconds 3
        Step 1 | Out-Null
        SecondaryState | Should Be 'Off'
        PrimaryState | Should Be 'Running'                  # released
        $script:state.Mode | Should Be 'Normal'
        Count "SELECT COUNT(*) FROM events WHERE action='HoldPrimary' AND result='OK'" | Should Be 1
        (Get-VmsDb).Scalar('SELECT failback_by FROM handoffs') | Should Match 'automatic failback'
    }

    It 'shuts the Secondary down cleanly as soon as a running Primary is back (no pause needed)' {
        Set-VmsSimVm -Role Primary -State Off
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'FailedOver'
        Set-VmsSimVm -Role Primary -State Running -PingOk $true
        Step 2 | Out-Null
        SecondaryState | Should Be 'Off'
        PrimaryState | Should Be 'Running'
        $script:state.Mode | Should Be 'Normal'
    }

    It 'never leaves both VMs ON: a Secondary started while the Primary runs is shut down cleanly' {
        Set-VmsSimVm -Role Secondary -State Running -PingOk $true -UptimeSeconds 50
        Step 2 | Out-Null
        SecondaryState | Should Be 'Off'
        PrimaryState | Should Be 'Running'
        Count "SELECT COUNT(*) FROM alerts WHERE title='Switching back to the Primary'" | Should Be 1
    }

    It 'powers OFF a frozen Primary before starting the Secondary' {
        Set-VmsSimVm -Role Primary -PingOk $false
        Step 3 | Out-Null
        $script:state.Mode | Should Be 'FailedOver'
        PrimaryState | Should Be 'Off'
        SecondaryState | Should Be 'Running'
        Count "SELECT COUNT(*) FROM events WHERE action='TurnOffPrimary' AND result='OK'" | Should Be 1
    }

    It 'raises a BOTH DOWN alert once when the Secondary cannot start, and retries' {
        Set-VmsSimVm -Role Secondary -Remove
        Set-VmsSimVm -Role Primary -State Off
        Step 1 | Out-Null
        Count "SELECT COUNT(*) FROM events WHERE action='StartSecondary' AND result='FAILED'" | Should Be 1
        Step 12 | Out-Null                                  # 36 s later: one retry (30 s)
        Count "SELECT COUNT(*) FROM events WHERE action='StartSecondary' AND result='FAILED'" | Should Be 2
        Count "SELECT COUNT(*) FROM alerts WHERE title='BOTH VMs ARE DOWN'" | Should Be 1
    }

    It 'remembers an active failover across a watchdog restart' {
        Set-VmsSimVm -Role Primary -State Off
        Step 1 | Out-Null
        $row = Get-VmsWatchdogRow
        $row.Mode | Should Be 'FailedOver'
        $row.Alive | Should Be $true
    }

    It 'waits after a host reboot before failing over a Primary that is still OFF' {
        $env:VMSWITCHER_HOST_UPTIME = '60'
        try {
            Set-VmsSimVm -Role Primary -State Off
            Step 3 | Out-Null
            $script:state.Mode | Should Be 'Normal'
            SecondaryState | Should Be 'Off'
            $env:VMSWITCHER_HOST_UPTIME = '400'
            Step 1 | Out-Null
            $script:state.Mode | Should Be 'FailedOver'
        } finally { Remove-Item Env:\VMSWITCHER_HOST_UPTIME -ErrorAction SilentlyContinue }
    }

    It 'treats a frozen Primary that just booted as STARTING, not failed' {
        Set-VmsSimVm -Role Primary -PingOk $false -UptimeSeconds 20
        Step 5 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        $script:state.Misses | Should Be 0
    }
}

Describe 'Menu options' {
    BeforeEach { Reset-World }
    AfterEach { Close-Vms; Remove-Item $script:homeDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'option 2 is refused while the Primary is ON (shared IP)' {
        $r = Invoke-VmsAction -Id StartSecondary
        $r.Result | Should Be 'REFUSED'
        $r.Message | Should Match 'same IP address'
        SecondaryState | Should Be 'Off'
    }

    It 'option 3 is refused when the Primary is not healthy' {
        Set-VmsSimVm -Role Primary -State Off
        (Invoke-VmsAction -Id StartSecondary).Result | Should Be 'OK'
        $r = Invoke-VmsAction -Id StopSecondary
        $r.Result | Should Be 'REFUSED'
        $r.Message | Should Match 'Turn ON the Primary first'
        SecondaryState | Should Be 'Running'
    }

    It 'option 3 powers OFF the Secondary when the Primary is healthy and closes the hand-off' {
        Set-VmsSimVm -Role Primary -State Off
        Step 1 | Out-Null
        Set-VmsSimVm -Role Primary -State Running -PingOk $true    # both ON for a moment
        (Invoke-VmsAction -Id StopSecondary).Result | Should Be 'OK'
        SecondaryState | Should Be 'Off'
        Step 1 | Out-Null
        $script:state.Mode | Should Be 'Normal'
        Count "SELECT COUNT(*) FROM handoffs WHERE status='Open'" | Should Be 0
    }

    It 'option 1 becomes "Restart Primary (frozen)" when the Primary is ON but not answering' {
        Set-VmsSimVm -Role Primary -State Running -PingOk $false -UptimeSeconds 9999
        $a = Get-VmsOptionAvailability (Get-VmsSnapshot)
        $a.StartPrimary.Enabled | Should Be $true
        $a.StartPrimary.Title | Should Be 'Restart Primary (frozen)'
        $r = Invoke-VmsAction -Id StartPrimary
        $r.Result | Should Be 'OK'
        $r.Message | Should Match 'restarted'
        (Get-VmsHealth Primary).IsHealthy | Should Be $true
    }

    It 'disables options with a reason' {
        $a = Get-VmsOptionAvailability (Get-VmsSnapshot)
        $a.StartPrimary.Enabled | Should Be $false
        $a.StartPrimary.Reason | Should Match 'already ON'
        $a.StopSecondary.Enabled | Should Be $false
        $a.StopSecondary.Reason | Should Match 'not ON'
    }

    It 'logs every user action with the program and Windows user' {
        Invoke-VmsAction -Id StartPrimary | Out-Null
        Count "SELECT COUNT(*) FROM events WHERE action='StartPrimary' AND source='Test'" | Should Be 1
        (Get-VmsDb).Scalar("SELECT actor FROM events WHERE action='StartPrimary'") | Should Match ([regex]::Escape($env:USERNAME))
    }

    It 'dry run explains now and what would happen on a crash' {
        $r = Invoke-VmsAction -Id TestFailover
        $r.Message | Should Match 'If the Primary crashed now'
        $r.Message | Should Match 'boots fully'
        SecondaryState | Should Be 'Off'
    }
}

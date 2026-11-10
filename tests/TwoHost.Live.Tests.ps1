# Integration test: two real watchdog processes on this PC act as the two servers.
#   A = Primary's server   (listens 47261, peer 47262)
#   B = Secondary's server (listens 47262, peer 47261)
# They talk over TCP with the shared key, exactly like 10.10.140.160 and 10.10.140.140 will.
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\src'
$modulePath = Join-Path $src 'VMSwitcher.Core.psm1'
$base = Join-Path $env:TEMP ('vms-2host-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$Hosts = @{
    A = @{ Home = "$base\A"; Role = 'Primary';   Listen = 47261; Peer = 47262 }
    B = @{ Home = "$base\B"; Role = 'Secondary'; Listen = 47262; Peer = 47261 }
}

function Use-Server([string]$Id) {
    $h = $Hosts[$Id]
    $env:VMSWITCHER_HOME = $h.Home; $env:VMSWITCHER_LOCALROLE = $h.Role; $env:VMSWITCHER_INSTANCE = $Id
    $env:VMSWITCHER_LISTENPORT = [string]$h.Listen; $env:VMSWITCHER_PEERPORT = [string]$h.Peer; $env:VMSWITCHER_PEERADDRESS = '127.0.0.1'
    $env:VMSWITCHER_PROVIDER = 'Simulated'; $env:VMSWITCHER_KEY = 'correct horse battery staple'; $env:VMSWITCHER_MUTE = '1'
    Import-Module $modulePath -Force -DisableNameChecking
    Initialize-Vms -Source 'Test'
}

function Start-Server([string]$Id) {
    Use-Server $Id
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$src\Watchdog.ps1`"" -PassThru -WindowStyle Hidden
    $Hosts[$Id].Proc = $p
}

function Wait-Until([scriptblock]$Cond, [int]$Seconds = 20) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}

function SimState([string]$Id, [string]$Role) {
    Use-Server $Id
    (Get-VmsProviderVm (Get-VmsVmConfig $Role).Name).State
}

Describe 'Two servers talking to each other' {
    foreach ($id in 'A', 'B') {
        Use-Server $id
        $sim = Read-VmsSim; $sim.BootSeconds = 0; Write-VmsSim $sim
        Close-Vms
    }
    # NOTE: no VM Switcher window and no terminal is started in this test. Only the two watchdogs run,
    # exactly like the Windows service does on the real servers when nobody is logged on.
    Start-Server A
    Start-Server B
    Start-Sleep -Seconds 6

    It 'each server sees the other server''s VM' {
        Use-Server B
        $snap = Get-VmsSnapshot
        $snap.LocalRole | Should Be 'Secondary'
        $snap.Primary.Reachable | Should Be $true
        $snap.Primary.IsLocal | Should Be $false
        $snap.Primary.Light | Should Be 'Green'
        $snap.Secondary.Light | Should Be 'Dark'
        Use-Server A
        (Get-VmsSnapshot).Secondary.ShortLabel | Should Be 'OFF'
    }

    It 'rejects a request signed with the wrong shared key' {
        Use-Server A
        { Invoke-VmsPeer -Method GET -Path '/vms/status' -KeyOverride 'wrong key' } | Should Throw 'do not match'
    }

    It 'turns ON the Secondary on server B when the Primary crashes on server A' {
        Use-Server A
        Set-VmsSimVm -Role Primary -State Off
        (Wait-Until { (SimState B Secondary) -eq 'Running' } 15) | Should Be $true
        Use-Server B
        [int](Get-VmsDb).Scalar("SELECT COUNT(*) FROM handoffs WHERE status='Open'") | Should Be 1
        (Wait-Until { Use-Server B; $null -ne (Get-VmsDb).Scalar("SELECT gap_seconds FROM handoffs WHERE status='Open'") } 10) | Should Be $true
    }

    It 'holds the returning Primary within 5 s, shuts the Secondary down cleanly, then releases the Primary (no window open)' {
        Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'VM Switcher*' } | Should BeNullOrEmpty
        Use-Server B; $sim = Read-VmsSim; $sim.StopSeconds = 4; Write-VmsSim $sim       # a clean shutdown takes 4 s here
        Start-Sleep -Seconds 2
        Use-Server A
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Set-VmsSimVm -Role Primary -State Running -PingOk $false -UptimeSeconds 1     # Hyper-V just started it (still booting)
        (Wait-Until { (SimState A Primary) -eq 'Paused' } 10) | Should Be $true
        $held = $sw.Elapsed.TotalSeconds
        # Sample both VMs until the Secondary is OFF. Read the Primary FIRST: if it already runs, the Secondary must be OFF.
        $violations = 0; $off = $null
        while ($sw.Elapsed.TotalSeconds -lt 25) {
            $ps = SimState A Primary; $ss = SimState B Secondary
            if ($ps -eq 'Running' -and $ss -ne 'Off') { $violations++ }
            if ($ss -eq 'Off') { $off = $sw.Elapsed.TotalSeconds; break }
            Start-Sleep -Milliseconds 150
        }
        $off | Should Not BeNullOrEmpty
        (Wait-Until { (SimState A Primary) -eq 'Running' } 10) | Should Be $true
        $back = $sw.Elapsed.TotalSeconds
        Write-Host ("      Primary held paused after {0:N1} s; Secondary OFF (clean) after {1:N1} s; Primary released after {2:N1} s" -f $held, $off, $back)
        $held | Should BeLessThan 5
        $violations | Should Be 0                              # the Primary never ran while the Secondary was ON
        Use-Server B
        (Get-VmsDb).Scalar("SELECT failback_by FROM handoffs ORDER BY id DESC LIMIT 1") | Should Match 'automatic failback'
        [int](Get-VmsDb).Scalar("SELECT COUNT(*) FROM events WHERE action IN ('StopSecondary','PeerStop')") | Should BeGreaterThan 0
        $sim = Read-VmsSim; $sim.StopSeconds = 0; Write-VmsSim $sim
    }

    It 'option 1 pressed on server B powers the Secondary OFF first, then starts the Primary on server A' {
        Use-Server A
        Set-VmsSimVm -Role Primary -State Off
        (Wait-Until { (SimState B Secondary) -eq 'Running' } 15) | Should Be $true
        Use-Server B
        $r = Invoke-VmsAction -Id StartPrimary
        $r.Result | Should Be 'OK'
        $r.Message | Should Match 'shut down cleanly first'
        SimState B Secondary | Should Be 'Off'
        SimState A Primary | Should Be 'Running'
        Use-Server A
        (Get-VmsDb).Scalar("SELECT actor FROM events WHERE action='PeerStart' ORDER BY id DESC LIMIT 1") | Should Match 'via Test'
    }

    It 'option 2 is refused while the Primary is ON (shared IP address)' {
        Use-Server A
        (Wait-Until { Use-Server A; (Get-VmsHealth Primary).IsUp } 10) | Should Be $true
        (Invoke-VmsAction -Id StartSecondary).Result | Should Be 'REFUSED'
        SimState B Secondary | Should Be 'Off'
    }

    It 'maintenance mode set on server A reaches server B' {
        Use-Server A
        (Invoke-VmsAction -Id SetMaintenance -On $true).Result | Should Be 'OK'
        Use-Server B
        (Get-VmsIntent 'maintenance') | Should Not BeNullOrEmpty
    }

    It 'option 3 pressed on server A powers OFF the Secondary on server B' {
        Use-Server B
        Set-VmsSimVm -Role Secondary -State Running -PingOk $true -UptimeSeconds 30    # someone started it in Hyper-V Manager
        Use-Server A
        (Wait-Until { Use-Server A; (Get-VmsHealth Primary).IsHealthy } 10) | Should Be $true
        $r = Invoke-VmsAction -Id StopSecondary
        Use-Server A
        (Invoke-VmsAction -Id SetMaintenance -On $false).Result | Should Be 'OK'
        $r.Result | Should Be 'OK'
        (Wait-Until { (SimState B Secondary) -eq 'Off' } 15) | Should Be $true          # clean shutdown
        Use-Server B
        (Get-VmsIntent 'maintenance') | Should BeNullOrEmpty
    }

    It 'server B fails over when server A goes completely silent (host down)' {
        Start-Sleep -Seconds 4
        Stop-Process -Id $Hosts.A.Proc.Id -Force        # server A's VM Switcher is gone...
        Use-Server B
        Set-VmsSimNetworkCut $true                       # ...and server A no longer answers ping
        (Wait-Until { (SimState B Secondary) -eq 'Running' } 25) | Should Be $true
        Use-Server B
        (Get-VmsDb).Scalar("SELECT message FROM events WHERE action='Failover' ORDER BY id DESC LIMIT 1") | Should Match 'completely silent'
    }

    foreach ($id in 'A', 'B') { try { Stop-Process -Id $Hosts[$id].Proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Close-Vms
    Start-Sleep -Seconds 1
    foreach ($v in 'HOME', 'LOCALROLE', 'INSTANCE', 'LISTENPORT', 'PEERPORT', 'PEERADDRESS', 'KEY') { Remove-Item "Env:\VMSWITCHER_$v" -ErrorAction SilentlyContinue }
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

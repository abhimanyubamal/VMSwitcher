# Pure decision tests for the two-server layout (no network): what each watchdog decides
# when the other server's VM is visible, invisible, or the other server is silent.
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\VMSwitcher.Core.psm1'

function New-World {
    $script:homeDir = Join-Path $env:TEMP ('vms-brain-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $env:VMSWITCHER_HOME = $script:homeDir
    New-Item -ItemType Directory -Force $script:homeDir | Out-Null; Set-Content (Join-Path $script:homeDir 'config.json') '{ "Primary": { "Name": "TEST-PRIMARY", "Host": "10.0.0.1" }, "Secondary": { "Name": "TEST-SECONDARY", "Host": "10.0.0.2" } }' -Encoding ASCII   # no built-in defaults any more
    $env:VMSWITCHER_PROVIDER = 'Simulated'
    $env:VMSWITCHER_LOCALROLE = 'Secondary'
    Import-Module $modulePath -Force -DisableNameChecking
    Initialize-Vms -Source 'Test'
    $script:cfg = Get-VmsConfig
    $script:st = New-VmsWatchdogState
    $script:now = Get-Date
}

function New-TestHealth([string]$Role, [string]$State, [string]$Hb = 'OK', [int]$Up = 9999) {
    $vc = Get-VmsVmConfig $Role
    ConvertTo-VmsHealth -Role $Role -Name $vc.Name -HostAddress $vc.Host -Vm @{ Exists = $true; State = $State; Status = ''; UptimeSeconds = $Up; Heartbeat = $Hb }
}

function Decide($P, $S, [bool]$Maint = $false) {
    $script:now = $script:now.AddSeconds(3)
    $d = Get-VmsWatchdogDecision -Primary $P -Secondary $S -State $script:st -Now $script:now -Config $script:cfg -Maintenance $Maint
    $script:st = $d.State
    return $d
}

function Types($d) { @($d.Actions | ForEach-Object { if ($_.Type -eq 'Event') { "Event:$($_.Action)" } else { $_.Type } }) }

Describe 'Two servers: what the Secondary''s server decides' {
    BeforeEach { New-World }
    AfterEach {
        Close-Vms
        Remove-Item Env:\VMSWITCHER_LOCALROLE -ErrorAction SilentlyContinue
        Remove-Item $script:homeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'fails over after 3 checks of total silence from the Primary''s server' {
        $silent = New-VmsUnreachableHealth -Role Primary -HostPing $false -Problem 'timeout'
        $sec = New-TestHealth Secondary 'Saved' 'No Contact'
        (Decide $silent $sec) | Out-Null
        (Decide $silent $sec) | Out-Null
        $script:st.Mode | Should Be 'Normal'
        $d = Decide $silent $sec
        $script:st.Mode | Should Be 'FailedOver'
        (Types $d) -contains 'StartSecondary' | Should Be $true
        ($d.Actions | Where-Object { $_.Type -eq 'Event' -and $_.Action -eq 'Failover' }).Message | Should Match 'went completely silent'
    }

    It 'only warns (once) when the Primary''s server pings but its VM Switcher is silent' {
        $blind = New-VmsUnreachableHealth -Role Primary -HostPing $true -Problem 'connection refused'
        $sec = New-TestHealth Secondary 'Saved' 'No Contact'
        $all = @(); for ($i = 0; $i -lt 6; $i++) { $all += Types (Decide $blind $sec) }
        $script:st.Mode | Should Be 'Normal'
        @($all | Where-Object { $_ -eq 'Event:PeerAppDown' }).Count | Should Be 1
        $all -contains 'StartSecondary' | Should Be $false
    }

    It 'does nothing while the remote Primary is healthy' {
        $d = Decide (New-TestHealth Primary 'Running') (New-TestHealth Secondary 'Saved' 'No Contact')
        $script:st.Mode | Should Be 'Normal'
        @($d.Actions).Count | Should Be 0
    }

    It 'fails over when the remote Primary''s heartbeat stops for 3 checks' {
        $frozen = New-TestHealth Primary 'Running' 'Lost Communication'
        $sec = New-TestHealth Secondary 'Saved' 'No Contact'
        Decide $frozen $sec | Out-Null; Decide $frozen $sec | Out-Null
        $script:st.Mode | Should Be 'Normal'
        $d = Decide $frozen $sec
        $script:st.Mode | Should Be 'FailedOver'
        ($d.Actions | Where-Object { $_.Action -eq 'Failover' }).Message | Should Match 'heartbeat'
    }

    It 'powers OFF the Secondary on the first check after contact with a still-running Primary comes back' {
        $silent = New-VmsUnreachableHealth -Role Primary -HostPing $false -Problem 'timeout'
        1..3 | ForEach-Object { Decide $silent (New-TestHealth Secondary 'Off' 'No Contact') | Out-Null }
        $script:st.Mode | Should Be 'FailedOver'
        $d = Decide (New-TestHealth Primary 'Running') (New-TestHealth Secondary 'Running')
        (Types $d) -contains 'ShutdownSecondary' | Should Be $true      # clean shutdown, data saved
        (Types $d) -contains 'HoldPrimary' | Should Be $false           # a long-running Primary is never paused
        (Types $d) -contains 'TurnOffSecondary' | Should Be $false      # no power cut
        $script:st.Mode | Should Be 'FailingBack'
        $d2 = Decide (New-TestHealth Primary 'Running') (New-TestHealth Secondary 'Off' 'No Contact')
        (Types $d2) -contains 'EndFailback' | Should Be $true
        (Types $d2) -contains 'Event:Failback' | Should Be $true
        $script:st.Mode | Should Be 'Normal'
    }

    It 'powers OFF the Secondary as soon as the Primary is merely STARTING (before its network is up)' {
        $off = New-TestHealth Primary 'Off' 'No Contact'
        Decide $off (New-TestHealth Secondary 'Off' 'No Contact') | Out-Null
        $script:st.Mode | Should Be 'FailedOver'
        $d = Decide (New-TestHealth Primary 'Starting' 'No Contact' 0) (New-TestHealth Secondary 'Running')
        (Types $d) -contains 'HoldPrimary' | Should Be $true            # paused before its network is up
        (Types $d) -contains 'ShutdownSecondary' | Should Be $true
        # while the held Primary is paused and the Secondary is stopping, nothing is mistaken for a failure:
        $d2 = Get-VmsWatchdogDecision -Primary (New-TestHealth Primary 'Paused' 'No Contact') -Secondary (New-TestHealth Secondary 'Stopping' 'No Contact') -State $script:st -Now $script:now.AddSeconds(3) -Config $script:cfg -FailbackActive $true
        (Types $d2) -contains 'StartSecondary' | Should Be $false
        $d2.State.Mode | Should Be 'FailingBack'
        $d3 = Get-VmsWatchdogDecision -Primary (New-TestHealth Primary 'Paused' 'No Contact') -Secondary (New-TestHealth Secondary 'Off' 'No Contact') -State $d2.State -Now $script:now.AddSeconds(6) -Config $script:cfg -FailbackActive $true
        (Types $d3) -contains 'ReleasePrimary' | Should Be $true
    }
}

Describe 'Two servers: what the Primary''s server decides' {
    BeforeEach { New-World; $env:VMSWITCHER_LOCALROLE = 'Primary'; [void](Get-VmsConfig -Reload) }
    AfterEach {
        Close-Vms
        Remove-Item Env:\VMSWITCHER_LOCALROLE -ErrorAction SilentlyContinue
        Remove-Item $script:homeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'warns once that there is no backup when the Secondary''s server is unreachable' {
        $p = New-TestHealth Primary 'Running'
        $gone = New-VmsUnreachableHealth -Role Secondary -HostPing $false -Problem 'timeout'
        $all = @(); for ($i = 0; $i -lt 5; $i++) { $all += Types (Decide $p $gone) }
        @($all | Where-Object { $_ -eq 'Event:BackupUnreachable' }).Count | Should Be 1
        $script:st.Mode | Should Be 'Normal'
    }

    It 'asks for the Secondary to be started when its own Primary crashes' {
        $d = Decide (New-TestHealth Primary 'Off' 'No Contact') (New-TestHealth Secondary 'Saved' 'No Contact')
        (Types $d) -contains 'StartSecondary' | Should Be $true
        $script:st.Mode | Should Be 'FailedOver'
    }
}

Describe 'Health from the Hyper-V heartbeat' {
    BeforeEach { New-World }
    AfterEach { Close-Vms; Remove-Item Env:\VMSWITCHER_LOCALROLE -ErrorAction SilentlyContinue; Remove-Item $script:homeDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'maps heartbeat states to lights' {
        (New-TestHealth Primary 'Running' 'OK').Light | Should Be 'Green'
        (New-TestHealth Primary 'Running' 'OK (Application Critical)').IsHealthy | Should Be $true
        $boot = New-TestHealth Primary 'Running' 'No Contact' 30
        $boot.Blink | Should Be $true
        $boot.Booting | Should Be $true
        $frozen = New-TestHealth Primary 'Running' 'Lost Communication'
        $frozen.Light | Should Be 'Grey'
        $frozen.IsFrozen | Should Be $true
        (New-TestHealth Primary 'Running' 'Disabled').Summary | Should Match 'DISABLED'
        $u = New-VmsUnreachableHealth -Role Primary -HostPing $false -Problem 'x'
        $u.ShortLabel | Should Be 'UNREACHABLE'
        $u.Reachable | Should Be $false
        (Get-VmsHealthWord $u) | Should Be 'UNREACHABLE (grey)'
    }
}

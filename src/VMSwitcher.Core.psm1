#requires -Version 5.1
# VMSwitcher core module (v2: two Hyper-V hosts, two cooperating apps).
#
#   Host 10.10.140.160 runs the PRIMARY VM   (VirtuoSIS_16.0.0_IICC)
#   Host 10.10.140.140 runs the SECONDARY VM (VirtuoSIS_16.0.0_IICC_STANDBY)
#
# The app is installed on both hosts. Each copy controls ONLY its own host's Hyper-V and learns
# about the other VM by asking the other copy (small HTTP endpoint, HMAC-signed with a shared key).
# A single-host layout (both VMs on one host, LocalRole = Both) still works and needs no peer.
#
# Shared by the watchdog service, the peer endpoint, the terminal menu and the windowed app.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:Db = $null
$script:Config = $null
$script:Source = 'Unknown'
$script:EventLogOk = $true
$script:EventLogSource = 'VMSwitcher'
$script:LocalRole = $null
$script:LocalRoleAt = [datetime]::MinValue
$script:Roles = @('Primary', 'Secondary')

# ---------------------------------------------------------------------------
# Paths, time helpers
# ---------------------------------------------------------------------------

function Get-VmsInstanceSuffix {
    <# Empty on real servers. Lets two simulated "servers" run side by side on one PC (demo/tests). #>
    if ($env:VMSWITCHER_INSTANCE) { return ".$($env:VMSWITCHER_INSTANCE)" }
    return ''
}

function Get-VmsHome {
    if ($env:VMSWITCHER_HOME) { return $env:VMSWITCHER_HOME }
    return (Join-Path $env:ProgramData 'VMSwitcher')
}

function Format-VmsTs($Time) {
    if ($null -eq $Time -or $Time -is [DBNull]) { return $null }
    return ([datetime]$Time).ToString('yyyy-MM-dd HH:mm:ss')
}

function ConvertFrom-VmsTs($Text) {
    if ($null -eq $Text -or $Text -is [DBNull] -or [string]::IsNullOrWhiteSpace([string]$Text)) { return $null }
    if ($Text -is [datetime]) { return $Text }
    return [datetime]::ParseExact([string]$Text, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-VmsActor {
    if ($env:USERDOMAIN) { return "$env:USERDOMAIN\$env:USERNAME" }
    return $env:USERNAME
}

function Format-VmsDuration([double]$Seconds) {
    $s = [math]::Max(0, [math]::Round($Seconds))
    if ($s -lt 60) { return "$s s" }
    $t = [TimeSpan]::FromSeconds($s)
    if ($t.TotalHours -lt 1) {
        if ($t.Seconds -eq 0) { return ('{0} min' -f $t.Minutes) }
        return ('{0} min {1} s' -f $t.Minutes, $t.Seconds)
    }
    if ($t.TotalDays -lt 1) { return ('{0} h {1} min' -f [int][math]::Floor($t.TotalHours), $t.Minutes) }
    return ('{0} d {1} h' -f [int][math]::Floor($t.TotalDays), $t.Hours)
}

function Get-VmsProp($Object, [string]$Name, $Default = $null) {
    <# Strict-mode-safe property read for objects that came over the wire. #>
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) { if ($Object.ContainsKey($Name)) { return $Object[$Name] } else { return $Default } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-VmsDefaultConfigPath {
    $candidates = @(
        (Join-Path $script:ModuleRoot 'config.default.json'),
        (Join-Path (Split-Path $script:ModuleRoot -Parent) 'config\config.default.json')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'config.default.json was not found next to the VMSwitcher module.'
}

function Get-VmsConfig {
    param([switch]$Reload)
    if ($script:Config -and -not $Reload) { return $script:Config }
    $default = Get-Content -LiteralPath (Get-VmsDefaultConfigPath) -Raw | ConvertFrom-Json
    $path = Join-Path (Get-VmsHome) 'config.json'
    if (Test-Path -LiteralPath $path) {
        $user = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($p in $default.PSObject.Properties) {
            if (-not ($user.PSObject.Properties.Name -contains $p.Name)) {
                $user | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
            }
        }
        $cfg = $user
    } else {
        $cfg = $default
    }
    # v1 configs used "Ip" (wrongly, as a VM address). v2 uses "Host" = the Hyper-V server.
    foreach ($r in $script:Roles) {
        $vc = $cfg.$r
        if (-not $vc.PSObject.Properties['Host']) { $vc | Add-Member -NotePropertyName Host -NotePropertyValue ([string](Get-VmsProp $vc 'Ip' '')) }
    }
    # Environment overrides (tests, two-host demo on one PC).
    if ($env:VMSWITCHER_PROVIDER) { $cfg.Provider = $env:VMSWITCHER_PROVIDER }
    if ($env:VMSWITCHER_LOCALROLE) { $cfg.LocalRole = $env:VMSWITCHER_LOCALROLE }
    if ($env:VMSWITCHER_LISTENPORT) { $cfg.ListenPort = [int]$env:VMSWITCHER_LISTENPORT }
    if ($env:VMSWITCHER_PEERPORT) { $cfg.PeerPort = [int]$env:VMSWITCHER_PEERPORT }
    if ($env:VMSWITCHER_PEERADDRESS) { $cfg.PeerAddress = $env:VMSWITCHER_PEERADDRESS }
    $script:Config = $cfg
    $script:LocalRole = $null
    return $cfg
}

function Get-VmsVmConfig([ValidateSet('Primary', 'Secondary')][string]$Role) {
    $cfg = Get-VmsConfig
    return $cfg.$Role
}

# ---------------------------------------------------------------------------
# Which VM lives on THIS server?
# ---------------------------------------------------------------------------

function Get-VmsLocalAddresses {
    try { return @([Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }) }
    catch { return @() }
}

function Get-VmsLocalRole {
    <#
      Primary | Secondary | Both | None.
      Order: config/env override -> which configured VM exists in local Hyper-V -> which host IP is ours.
      Cached for 60 s.
    #>
    param([switch]$Refresh)
    if ($script:LocalRole -and -not $Refresh -and ((Get-Date) - $script:LocalRoleAt).TotalSeconds -lt 60) { return $script:LocalRole }
    $cfg = Get-VmsConfig
    $role = [string]$cfg.LocalRole
    if ($role -notin 'Primary', 'Secondary', 'Both') {
        $hasP = $false; $hasS = $false
        try { $hasP = (Get-VmsProviderVm $cfg.Primary.Name).Exists; $hasS = (Get-VmsProviderVm $cfg.Secondary.Name).Exists } catch { }
        if ($hasP -and $hasS) { $role = 'Both' }
        elseif ($hasP) { $role = 'Primary' }
        elseif ($hasS) { $role = 'Secondary' }
        else {
            $mine = Get-VmsLocalAddresses
            if ($mine -contains [string]$cfg.Primary.Host) { $role = 'Primary' }
            elseif ($mine -contains [string]$cfg.Secondary.Host) { $role = 'Secondary' }
            else { $role = 'None' }
        }
    }
    $script:LocalRole = $role
    $script:LocalRoleAt = Get-Date
    return $role
}

function Test-VmsRoleIsLocal([string]$Role) {
    $lr = Get-VmsLocalRole
    return ($lr -eq 'Both' -or $lr -eq $Role)
}

function Get-VmsRemoteRole {
    switch (Get-VmsLocalRole) { 'Primary' { return 'Secondary' } 'Secondary' { return 'Primary' } default { return $null } }
}

function Get-VmsPeerAddress {
    $cfg = Get-VmsConfig
    if ($cfg.PeerAddress) { return [string]$cfg.PeerAddress }
    $rr = Get-VmsRemoteRole
    if ($rr) { return [string]$cfg.$rr.Host }
    return $null
}

function Get-VmsServerLabel([string]$Role) {
    <# "10.10.140.160 (this server)" or "10.10.140.140 (other server)". #>
    $h = [string](Get-VmsVmConfig $Role).Host
    if (Test-VmsRoleIsLocal $Role) { return "$h (this server)" }
    return "$h (other server)"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

function Import-VmsSqlite {
    if ('VMSwitcher.SqliteDb' -as [type]) { return }
    $dll = Join-Path $script:ModuleRoot 'lib\VMSwitcher.Native.dll'
    if (Test-Path -LiteralPath $dll) {
        [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
    } else {
        $src = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'lib\VmsSqlite.cs') -Raw
        Add-Type -TypeDefinition $src -ReferencedAssemblies 'System.Data', 'System.Xml'
    }
}

$script:Schema = @'
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    severity TEXT NOT NULL,          -- Info | Warning | Critical
    source TEXT NOT NULL,            -- Watchdog | GUI | Terminal | Peer | Installer
    actor TEXT,                      -- Windows user who caused it
    vm_role TEXT,                    -- Primary | Secondary | NULL
    vm_name TEXT,
    action TEXT NOT NULL,            -- machine-friendly action key
    result TEXT NOT NULL,            -- OK | FAILED | REFUSED | NOOP | INFO | ALERT
    message TEXT NOT NULL,           -- plain English sentence for humans
    detail TEXT
);
CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts);
CREATE TABLE IF NOT EXISTS vm_transitions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    vm_role TEXT NOT NULL,
    vm_name TEXT NOT NULL,
    from_light TEXT, to_light TEXT,
    from_state TEXT, to_state TEXT,
    message TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS handoffs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger TEXT NOT NULL,           -- Automatic | Planned
    reason TEXT NOT NULL,
    primary_down_ts TEXT,
    secondary_up_ts TEXT,
    gap_seconds REAL,
    failback_ts TEXT,
    failback_by TEXT,
    status TEXT NOT NULL DEFAULT 'Open'
);
CREATE TABLE IF NOT EXISTS intents (
    name TEXT PRIMARY KEY,
    value TEXT,
    set_by TEXT,
    set_ts TEXT,
    expires_ts TEXT
);
CREATE TABLE IF NOT EXISTS status (
    role TEXT PRIMARY KEY,
    vm_name TEXT, light TEXT, blink INTEGER, label TEXT, state TEXT,
    ping_ok INTEGER, ping_ms INTEGER, uptime_s INTEGER, heartbeat TEXT,
    summary TEXT, updated_ts TEXT
);
CREATE TABLE IF NOT EXISTS watchdog (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    mode TEXT, message TEXT, state_json TEXT,
    last_tick_ts TEXT, started_ts TEXT, pid INTEGER
);
CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    severity TEXT NOT NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL
);
'@

function Initialize-Vms {
    <# Opens config + database for the calling program. Source = Watchdog | GUI | Terminal | Peer | Test. #>
    param([string]$Source = 'Unknown')
    $script:Source = $Source
    $vmsHome = Get-VmsHome
    foreach ($d in @($vmsHome, (Join-Path $vmsHome 'logs'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    [void](Get-VmsConfig -Reload)
    Import-VmsSqlite
    if ($script:Db) { $script:Db.Dispose() }
    $script:Db = New-Object VMSwitcher.SqliteDb -ArgumentList (Join-Path $vmsHome 'vmswitcher.db'), 10000
    $script:Db.ExecScript($script:Schema)
}

function Get-VmsDb {
    if (-not $script:Db) { throw 'VMSwitcher is not initialised. Call Initialize-Vms first.' }
    return $script:Db
}

function Close-Vms {
    if ($script:Db) { $script:Db.Dispose(); $script:Db = $null }
}

# ---------------------------------------------------------------------------
# Logging: database rows + daily text file + Windows Event Log + desktop alerts
# ---------------------------------------------------------------------------

function Write-VmsTextLog([string]$Line) {
    $dir = Join-Path (Get-VmsHome) 'logs'
    $file = Join-Path $dir ('VMSwitcher-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::AppendAllText($file, $Line + [Environment]::NewLine, [Text.Encoding]::UTF8); return }
        catch { Start-Sleep -Milliseconds 40 }
    }
}

function Write-VmsWindowsEvent([string]$Severity, [string]$Message) {
    if (-not $script:EventLogOk) { return }
    $type = switch ($Severity) { 'Critical' { 'Error' } 'Warning' { 'Warning' } default { 'Information' } }
    $id = switch ($Severity) { 'Critical' { 3000 } 'Warning' { 2000 } default { 1000 } }
    try { [Diagnostics.EventLog]::WriteEntry($script:EventLogSource, $Message, $type, $id) }
    catch { $script:EventLogOk = $false }   # source not registered (installer does it) or no rights
}

function Write-VmsEvent {
    param(
        [ValidateSet('Info', 'Warning', 'Critical')][string]$Severity = 'Info',
        [Parameter(Mandatory)][string]$Action,
        [string]$Result = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('', 'Primary', 'Secondary')][string]$Role = '',
        [string]$Detail = '',
        [switch]$Alert,
        [string]$Title = '',
        [string]$Actor = ''
    )
    $now = Get-Date
    $vmName = $null
    if ($Role) { $vmName = (Get-VmsVmConfig $Role).Name }
    if (-not $Actor) { $Actor = Get-VmsActor }
    [void](Get-VmsDb).Insert(
        'INSERT INTO events(ts,severity,source,actor,vm_role,vm_name,action,result,message,detail) VALUES (?,?,?,?,?,?,?,?,?,?)',
        @((Format-VmsTs $now), $Severity, $script:Source, $Actor, $Role, $vmName, $Action, $Result, $Message, $Detail))
    $line = '{0}  {1,-8}  {2,-9}  {3,-7}  {4}' -f (Format-VmsTs $now), $Severity.ToUpper(), $script:Source, $Result, $Message
    if ($Detail) { $line += "  [$Detail]" }
    Write-VmsTextLog $line
    $who = if ($script:Source -eq 'Watchdog') { 'automatic watchdog' } else { "$Actor via $script:Source" }
    Write-VmsWindowsEvent $Severity ("{0}`r`n`r`nBy: {1}`r`nAction: {2} ({3})" -f $Message, $who, $Action, $Result)
    if ($Alert) {
        if (-not $Title) { $Title = 'VM Switcher' }
        # De-duplicate: the same alert title is raised at most once per AlertRepeatMinutes.
        $since = Format-VmsTs ($now.AddMinutes(-[int](Get-VmsConfig).AlertRepeatMinutes))
        $dup = [int](Get-VmsDb).Scalar('SELECT COUNT(*) FROM alerts WHERE title = ? AND ts >= ?', @($Title, $since))
        if ($dup -eq 0) {
            [void](Get-VmsDb).Insert('INSERT INTO alerts(ts,severity,title,message) VALUES (?,?,?,?)',
                @((Format-VmsTs $now), $Severity, $Title, $Message))
        }
    }
}

function Write-VmsTransition {
    param([string]$Role, [string]$FromLight, [string]$ToLight, [string]$FromState, [string]$ToState, [string]$Message)
    $name = (Get-VmsVmConfig $Role).Name
    [void](Get-VmsDb).Insert(
        'INSERT INTO vm_transitions(ts,vm_role,vm_name,from_light,to_light,from_state,to_state,message) VALUES (?,?,?,?,?,?,?,?)',
        @((Format-VmsTs (Get-Date)), $Role, $name, $FromLight, $ToLight, $FromState, $ToState, $Message))
    Write-VmsTextLog ('{0}  CHANGE    {1,-9}  {2,-7}  {3}' -f (Format-VmsTs (Get-Date)), $script:Source, $Role, $Message)
}

function Get-VmsAlertsSince([long]$LastId) {
    return , (Get-VmsDb).Query('SELECT id,ts,severity,title,message FROM alerts WHERE id > ? ORDER BY id', @($LastId))
}

function Get-VmsLastAlertId {
    $v = (Get-VmsDb).Scalar('SELECT IFNULL(MAX(id),0) FROM alerts')
    return [long]$v
}

# ---------------------------------------------------------------------------
# Intents: "this is on purpose" flags. Replicated to the other server so both apps agree.
# ---------------------------------------------------------------------------

function Set-VmsIntent {
    param([string]$Name, [string]$Value = '1', [int]$ExpiresSeconds = 0, [switch]$Replicate, [string]$SetBy = '')
    $now = Get-Date
    $exp = $null
    if ($ExpiresSeconds -gt 0) { $exp = Format-VmsTs ($now.AddSeconds($ExpiresSeconds)) }
    if (-not $SetBy) { $SetBy = "$(Get-VmsActor) via $script:Source" }
    [void](Get-VmsDb).Execute('INSERT OR REPLACE INTO intents(name,value,set_by,set_ts,expires_ts) VALUES (?,?,?,?,?)',
        @($Name, $Value, $SetBy, (Format-VmsTs $now), $exp))
    if ($Replicate) { Send-VmsIntentToPeer -Name $Name -Value $Value -ExpiresSeconds $ExpiresSeconds -SetBy $SetBy }
}

function Get-VmsIntent([string]$Name) {
    $t = (Get-VmsDb).Query('SELECT name,value,set_by,set_ts,expires_ts FROM intents WHERE name = ?', @($Name))
    if ($t.Rows.Count -eq 0) { return $null }
    $r = $t.Rows[0]
    $exp = ConvertFrom-VmsTs $r.expires_ts
    if ($exp -and $exp -lt (Get-Date)) {
        Clear-VmsIntent $Name
        return $null
    }
    return [pscustomobject]@{ Name = $r.name; Value = [string]$r.value; SetBy = [string]$r.set_by; SetTs = [string]$r.set_ts; Expires = $exp }
}

function Clear-VmsIntent([string]$Name, [switch]$Replicate) {
    [void](Get-VmsDb).Execute('DELETE FROM intents WHERE name = ?', @($Name))
    if ($Replicate) { Send-VmsIntentToPeer -Name $Name -Clear }
}

function Send-VmsIntentToPeer {
    param([string]$Name, [string]$Value = '1', [int]$ExpiresSeconds = 0, [string]$SetBy = '', [switch]$Clear)
    if (-not (Get-VmsRemoteRole)) { return }
    try {
        [void](Invoke-VmsPeer -Method POST -Path '/vms/intent' -Body @{ Name = $Name; Value = $Value; ExpiresSeconds = $ExpiresSeconds; SetBy = $SetBy; Clear = [bool]$Clear })
    } catch {
        Write-VmsEvent -Severity Warning -Action 'IntentSync' -Result 'FAILED' -Message "Could not tell VM Switcher on $(Get-VmsPeerAddress) about '$Name'. It will not know until it is reachable again. ($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Hand-offs: "when did one VM stop and the other turn ON".
# Recorded by the app on the SECONDARY's server (it is the one that survives a Primary-host failure).
# ---------------------------------------------------------------------------

function Test-VmsKeepsHandoffs { return (Get-VmsLocalRole) -in 'Secondary', 'Both', 'None' }

function New-VmsHandoff {
    param([ValidateSet('Automatic', 'Planned')][string]$Trigger, [string]$Reason, [datetime]$PrimaryDown)
    return (Get-VmsDb).Insert('INSERT INTO handoffs(trigger,reason,primary_down_ts,status) VALUES (?,?,?,''Open'')',
        @($Trigger, $Reason, (Format-VmsTs $PrimaryDown)))
}

function Set-VmsHandoffSecondaryUp {
    param([long]$Id, [datetime]$SecondaryUp)
    $row = (Get-VmsDb).Query('SELECT primary_down_ts FROM handoffs WHERE id = ?', @($Id))
    if ($row.Rows.Count -eq 0) { return $null }
    $down = ConvertFrom-VmsTs $row.Rows[0].primary_down_ts
    $SecondaryUp = ConvertFrom-VmsTs (Format-VmsTs $SecondaryUp)   # same whole-second precision as the stored times
    $gap = $null
    if ($down) { $gap = [math]::Round(($SecondaryUp - $down).TotalSeconds, 1) }
    [void](Get-VmsDb).Execute('UPDATE handoffs SET secondary_up_ts = ?, gap_seconds = ? WHERE id = ? AND secondary_up_ts IS NULL',
        @((Format-VmsTs $SecondaryUp), $gap, $Id))
    return $gap
}

function Close-VmsOpenHandoffs([string]$By) {
    return (Get-VmsDb).Execute('UPDATE handoffs SET failback_ts = ?, failback_by = ?, status = ''Closed'' WHERE status = ''Open''',
        @((Format-VmsTs (Get-Date)), $By))
}

function Get-VmsOpenHandoff {
    $t = (Get-VmsDb).Query('SELECT * FROM handoffs WHERE status = ''Open'' ORDER BY id DESC LIMIT 1')
    if ($t.Rows.Count -eq 0) { return $null }
    return $t.Rows[0]
}

function Get-VmsOpenHandoffInfo {
    <# Small, wire-friendly summary of the open hand-off on THIS server (or $null). #>
    $h = Get-VmsOpenHandoff
    if (-not $h) { return $null }
    $gap = $null
    if ($h.gap_seconds -isnot [DBNull]) { $gap = [double]$h.gap_seconds }
    return [pscustomobject]@{ PrimaryDown = [string]$h.primary_down_ts; GapSeconds = $gap; Reason = [string]$h.reason }
}

# ---------------------------------------------------------------------------
# Local providers: Hyper-V (real) and Simulated (JSON file, for demo and tests)
# ---------------------------------------------------------------------------

function Get-VmsSimPath { return (Join-Path (Get-VmsHome) 'simulation.json') }

function Read-VmsSim {
    $path = Get-VmsSimPath
    if (-not (Test-Path -LiteralPath $path)) {
        $cfg = Get-VmsConfig
        $now = Format-VmsTs ((Get-Date).AddHours(-5))
        $vms = [ordered]@{}
        # A simulated host only holds the VM(s) that belong to it.
        $lr = [string]$cfg.LocalRole
        if ($lr -in 'Auto', 'Both', 'Primary', '') {
            $vms[[string]$cfg.Primary.Name] = [ordered]@{ State = 'Running'; PingOk = $true; Heartbeat = 'OK'; StartedAt = $now; BootUntil = $now }
        }
        if ($lr -in 'Auto', 'Both', 'Secondary', '') {
            $vms[[string]$cfg.Secondary.Name] = [ordered]@{ State = 'Off'; PingOk = $true; Heartbeat = 'No Contact'; StartedAt = $null; BootUntil = $null }
        }
        Write-VmsSim ([pscustomobject]@{ BootSeconds = 8; StopSeconds = 5; VMs = $vms })
    }
    for ($i = 0; $i -lt 10; $i++) {
        try { $sim = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; break }
        catch { $sim = $null; Start-Sleep -Milliseconds 30 }
    }
    if (-not $sim) { throw "Cannot read simulation file $path" }
    # A simulated clean shutdown finishes after StopSeconds.
    $changed = $false
    foreach ($pr in $sim.VMs.PSObject.Properties) {
        $v = $pr.Value
        $until = Get-VmsProp $v 'StopUntil'
        if ($v.State -eq 'Stopping' -and $until -and (ConvertFrom-VmsTs $until) -le (Get-Date)) { $v.State = 'Off'; $v.StartedAt = $null; $changed = $true }
    }
    if ($changed) { Write-VmsSim $sim }
    return $sim
}

function Get-VmsSimEntry($Sim, [string]$Name) {
    $prop = $Sim.VMs.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Write-VmsSim($Sim) {
    $json = $Sim | ConvertTo-Json -Depth 5
    for ($i = 0; $i -lt 10; $i++) {
        try { [IO.File]::WriteAllText((Get-VmsSimPath), $json, [Text.Encoding]::UTF8); return }
        catch { Start-Sleep -Milliseconds 30 }
    }
}

function Set-VmsSimVm {
    <# Test/demo helper: force a simulated VM into a state. PingOk = the guest answers (heartbeat OK). #>
    param([ValidateSet('Primary', 'Secondary')][string]$Role, [string]$State, [Nullable[bool]]$PingOk, [Nullable[int]]$UptimeSeconds, [switch]$Remove)
    $sim = Read-VmsSim
    $name = (Get-VmsVmConfig $Role).Name
    if ($Remove) { $sim.VMs.PSObject.Properties.Remove($name); Write-VmsSim $sim; return }
    $vm = Get-VmsSimEntry $sim $name
    if (-not $vm) {
        $vm = [pscustomobject]@{ State = 'Off'; PingOk = $false; Heartbeat = ''; StartedAt = $null; BootUntil = $null }
        $sim.VMs | Add-Member -NotePropertyName $name -NotePropertyValue $vm
    }
    if ($State) { $vm.State = $State }
    if ($null -ne $PingOk) { $vm.PingOk = [bool]$PingOk; $vm.BootUntil = Format-VmsTs (Get-Date).AddSeconds(-1) }
    if ($null -ne $UptimeSeconds) { $vm.StartedAt = Format-VmsTs ((Get-Date).AddSeconds(-$UptimeSeconds)) }
    Write-VmsSim $sim
}

function Get-VmsSimNetFlag { return (Join-Path (Get-VmsHome) 'sim-network-cut.flag') }

function Set-VmsSimNetworkCut([bool]$Cut) {
    <# Demo/test: pretend this server lost its network to the other server (no ping, no app). #>
    $f = Get-VmsSimNetFlag
    if ($Cut) { Set-Content -LiteralPath $f -Value (Get-Date) } elseif (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

function Test-VmsSimNetworkCut {
    return ((Get-VmsConfig).Provider -eq 'Simulated' -and (Test-Path -LiteralPath (Get-VmsSimNetFlag)))
}

function Get-VmsProviderVm([string]$Name) {
    <# Raw facts about a VM on THIS server's Hyper-V. Heartbeat = Hyper-V integration service status. #>
    $cfg = Get-VmsConfig
    if ($cfg.Provider -eq 'Simulated') {
        $sim = Read-VmsSim
        $vm = Get-VmsSimEntry $sim $Name
        if (-not $vm) { return @{ Exists = $false; State = 'Missing'; Status = ''; UptimeSeconds = 0; Heartbeat = '' } }
        $started = ConvertFrom-VmsTs $vm.StartedAt
        $up = 0
        if ($vm.State -eq 'Running' -and $started) { $up = [int]((Get-Date) - $started).TotalSeconds }
        $hb = 'No Contact'
        if ($vm.State -eq 'Running') {
            $boot = ConvertFrom-VmsTs $vm.BootUntil
            if ($boot -and $boot -gt (Get-Date)) { $hb = 'No Contact' }
            elseif ($vm.PingOk) { $hb = 'OK' }
            else { $hb = 'Lost Communication' }
        }
        return @{ Exists = $true; State = [string]$vm.State; Status = 'Operating normally'; UptimeSeconds = $up; Heartbeat = $hb }
    }
    Import-Module Hyper-V -ErrorAction Stop -Verbose:$false | Out-Null
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { return @{ Exists = $false; State = 'Missing'; Status = ''; UptimeSeconds = 0; Heartbeat = '' } }
    $hb = ''
    try {
        $svc = Get-VMIntegrationService -VM $vm -ErrorAction Stop | Where-Object { $_.Name -eq 'Heartbeat' -or $_.Name -like '*Heartbeat*' } | Select-Object -First 1
        if ($svc) {
            if (-not $svc.Enabled) { $hb = 'Disabled' } else { $hb = [string]$svc.PrimaryStatusDescription }
        }
    } catch { $hb = '' }
    return @{ Exists = $true; State = [string]$vm.State; Status = [string]$vm.Status; UptimeSeconds = [int]$vm.Uptime.TotalSeconds; Heartbeat = $hb }
}

function Test-VmsHostPing([string]$Address) {
    <# One ICMP echo to a SERVER, the same as `ping <ip> -n 1`, with a short timeout. #>
    $cfg = Get-VmsConfig
    if ($cfg.Provider -eq 'Simulated') { return (-not (Test-VmsSimNetworkCut)) }
    if (-not $Address) { return $false }
    $ping = New-Object System.Net.NetworkInformation.Ping
    try { return ($ping.Send($Address, [int]$cfg.PingTimeoutMs).Status -eq [System.Net.NetworkInformation.IPStatus]::Success) }
    catch { return $false }
    finally { $ping.Dispose() }
}

function Invoke-VmsProviderOp {
    param([ValidateSet('Start', 'Save', 'Stop', 'Restart', 'TurnOff', 'Pause')][string]$Op, [string]$Name)
    $cfg = Get-VmsConfig
    if ($cfg.Provider -eq 'Simulated') {
        $sim = Read-VmsSim
        $vm = Get-VmsSimEntry $sim $Name
        if (-not $vm) { throw "Virtual machine '$Name' was not found on this server." }
        $now = Get-Date
        switch ($Op) {
            'Start' {
                $wasSaved = $vm.State -in 'Saved', 'Paused'
                $vm.State = 'Running'; $vm.PingOk = $true; $vm.Heartbeat = 'OK'
                if (-not $wasSaved -or -not $vm.StartedAt) { $vm.StartedAt = Format-VmsTs $now }
                $vm.BootUntil = if ($wasSaved) { Format-VmsTs $now } else { Format-VmsTs ($now.AddSeconds([int]$sim.BootSeconds)) }
            }
            'Save' { $vm.State = 'Saved'; $vm.Heartbeat = 'No Contact' }
            'Stop' {
                $secs = [int](Get-VmsProp $sim 'StopSeconds' 0)
                if ($secs -gt 0) {
                    $vm.State = 'Stopping'; $vm.Heartbeat = 'No Contact'
                    if ($vm.PSObject.Properties['StopUntil']) { $vm.StopUntil = Format-VmsTs ($now.AddSeconds($secs)) } else { $vm | Add-Member -NotePropertyName StopUntil -NotePropertyValue (Format-VmsTs ($now.AddSeconds($secs))) }
                } else { $vm.State = 'Off'; $vm.Heartbeat = 'No Contact'; $vm.StartedAt = $null }
            }
            'TurnOff' { $vm.State = 'Off'; $vm.Heartbeat = 'No Contact'; $vm.StartedAt = $null }
            'Pause' { $vm.State = 'Paused' }
            'Restart' { $vm.State = 'Running'; $vm.PingOk = $true; $vm.Heartbeat = 'OK'; $vm.StartedAt = Format-VmsTs $now; $vm.BootUntil = Format-VmsTs ($now.AddSeconds([int]$sim.BootSeconds)) }
        }
        Write-VmsSim $sim
        return
    }
    Import-Module Hyper-V -ErrorAction Stop -Verbose:$false | Out-Null
    switch ($Op) {
        'Start' {
            $vm = Get-VM -Name $Name -ErrorAction Stop
            if ([string]$vm.State -eq 'Paused') { Resume-VM -VM $vm -ErrorAction Stop | Out-Null }
            else { Start-VM -VM $vm -ErrorAction Stop | Out-Null }
        }
        'Save' { Save-VM -Name $Name -ErrorAction Stop | Out-Null }
        'Stop' {
            # Graceful guest shutdown (applications close cleanly) in a separate hidden process, so the caller
            # (watchdog, peer endpoint, GUI) returns at once and monitoring never pauses. If Windows inside the VM
            # has not finished after ShutdownTimeoutSeconds, the VM is powered off.
            [void](Get-VM -Name $Name -ErrorAction Stop)
            $t = [int]$cfg.ShutdownTimeoutSeconds
            $n = $Name.Replace("'", "''")
            $script = "Import-Module Hyper-V; `$j = Stop-VM -Name '$n' -Force -AsJob; if (-not (Wait-Job `$j -Timeout $t)) { Stop-VM -Name '$n' -TurnOff -Force }"
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
            Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc) -WindowStyle Hidden | Out-Null
        }
        'Restart' { Restart-VM -Name $Name -Force -ErrorAction Stop | Out-Null }   # hard reset of a frozen VM
        'TurnOff' { Stop-VM -Name $Name -TurnOff -Force -Confirm:$false -ErrorAction Stop | Out-Null }   # last resort only: instant power-off
        'Pause' { Suspend-VM -Name $Name -ErrorAction Stop | Out-Null }   # freeze in memory: nothing is lost, resumes exactly where it was
    }
}

function Get-VmsOffReason([string]$Name) {
    <# Best-effort: look at Hyper-V worker events from the last 2 minutes to explain why a VM stopped. #>
    if ((Get-VmsConfig).Provider -eq 'Simulated') { return '' }
    try {
        $since = (Get-Date).AddMinutes(-2)
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Hyper-V-Worker-Admin'; StartTime = $since } -MaxEvents 30 -ErrorAction Stop |
            Where-Object { $_.Message -like "*$Name*" } | Select-Object -First 1
        if (-not $ev) { return '' }
        switch ($ev.Id) {
            18590 { return 'Hyper-V reports the guest operating system crashed.' }
            18560 { return 'Hyper-V reports the VM was turned off because the guest was reset or crashed.' }
            18504 { return 'The guest operating system shut itself down.' }
            18502 { return 'The VM was turned off from Hyper-V.' }
            default { return ('Hyper-V event {0}: {1}' -f $ev.Id, ($ev.Message -split "`n")[0]) }
        }
    } catch { return '' }
}

# ---------------------------------------------------------------------------
# Health: the lights
# ---------------------------------------------------------------------------

$script:LightWords = @{ Green = 'OK (green)'; Yellow = 'SUSPENDED (yellow)'; Grey = 'ERROR (grey)'; Dark = 'OFF (dark)' }

function Get-VmsLightWord([string]$Light) {
    if ($script:LightWords.ContainsKey($Light)) { return $script:LightWords[$Light] }
    return $Light
}

function Get-VmsHealthWord($Health) {
    <# 'OK (green)', 'STARTING (blinking green)', 'UNREACHABLE (grey)' ... from a health object. #>
    if (-not $Health.Reachable) { return 'UNREACHABLE (grey)' }
    if ($Health.Blink) {
        $colour = @{ Green = 'green'; Yellow = 'yellow'; Grey = 'grey'; Dark = 'dark' }[$Health.Light]
        return ('{0} (blinking {1})' -f $Health.ShortLabel.TrimEnd('.'), $colour)
    }
    return (Get-VmsLightWord $Health.Light)
}

function New-VmsHealthObject {
    param($Role, $Name, $HostAddress, $Exists, $State, $Critical, $Status, $Uptime, $Heartbeat, $Responsive, $Light, $Blink,
        $Label, $Symbol, $Ascii, $Summary, $Booting, $IsUp, [bool]$IsLocal = $true, [bool]$Reachable = $true, [bool]$HostPing = $true, [string]$PeerProblem = '')
    $healthy = ($Reachable -and $Light -eq 'Green' -and -not $Blink)
    return [pscustomobject]@{
        Role          = $Role
        Name          = $Name
        Host          = $HostAddress
        IsLocal       = $IsLocal
        Reachable     = $Reachable
        HostPing      = $HostPing
        PeerProblem   = $PeerProblem
        Exists        = [bool]$Exists
        State         = [string]$State
        Critical      = [bool]$Critical
        Status        = [string]$Status
        UptimeSeconds = [int]$Uptime
        Heartbeat     = [string]$Heartbeat
        PingOk        = [bool]$Responsive          # "the guest is responding" (heartbeat OK); name kept for compatibility
        Light         = $Light
        Blink         = [bool]$Blink
        Label         = "HEALTH STATUS: $Label"
        ShortLabel    = $Label
        Symbol        = $Symbol
        Ascii         = $Ascii
        Summary       = $Summary
        Booting       = [bool]$Booting
        IsHealthy     = $healthy
        IsFrozen      = ($Reachable -and [bool]$Exists -and $State -eq 'Running' -and -not $Responsive -and -not $Booting)
        IsUp          = ($Reachable -and [bool]$IsUp)
        Transitional  = ($Reachable -and [bool]$Blink)
        Time          = Get-Date
    }
}

function ConvertTo-VmsHealth {
    <# Pure function: raw local VM facts (incl. Hyper-V heartbeat) -> light, label, symbol, sentence. #>
    param(
        [string]$Role, [string]$Name, [string]$HostAddress = '',
        [hashtable]$Vm, [int]$BootGraceSeconds = 180
    )
    $state = [string]$Vm.State
    $critical = $state -like '*Critical'
    $hb = [string]$Vm.Heartbeat
    $responsive = $hb -like 'OK*'
    $light = 'Grey'; $blink = $false; $label = 'ERROR'; $summary = ''; $booting = $false
    $ascii = '[!!]'; $symbol = [string][char]0x2716
    if (-not $Vm.Exists) {
        $summary = "Not found in Hyper-V on $HostAddress. Check that a VM named '$Name' exists on that server."
    } elseif ($critical) {
        $summary = "Hyper-V reports a CRITICAL problem (state: $state). This is often a full or missing disk on the server."
    } else {
        switch ($state) {
            'Running' {
                if ($responsive) {
                    $light = 'Green'; $label = 'OK'; $symbol = [string][char]0x2714; $ascii = '[OK]'
                    $summary = 'Running normally. Windows inside the VM reports its heartbeat.'
                } elseif ($hb -eq 'Disabled') {
                    $summary = 'Running, but the Hyper-V heartbeat service is DISABLED for this VM, so its health cannot be checked. Enable it in Hyper-V Manager > Settings > Integration Services.'
                } elseif ($Vm.UptimeSeconds -lt $BootGraceSeconds) {
                    $booting = $true
                    $light = 'Green'; $blink = $true; $label = 'STARTING...'; $symbol = [string][char]0x21BB; $ascii = '[..]'
                    $summary = "Turned ON $(Format-VmsDuration $Vm.UptimeSeconds) ago. Waiting for Windows inside the VM to report its heartbeat."
                } else {
                    $summary = "Running in Hyper-V but its heartbeat stopped ($(if ($hb) { $hb } else { 'no heartbeat' })). The VM may be frozen."
                }
            }
            { $_ -in 'Saved', 'FastSaved' } {
                $light = 'Yellow'; $label = 'SUSPENDED'; $symbol = [string][char]0x275A + [char]0x275A; $ascii = '[ZZ]'
                $summary = 'Hibernated (saved to disk). It can resume in a few seconds.'
            }
            'Paused' {
                $light = 'Yellow'; $label = 'SUSPENDED'; $symbol = [string][char]0x275A + [char]0x275A; $ascii = '[ZZ]'
                $summary = 'Paused (frozen in memory). It can resume instantly.'
            }
            'Off' {
                $light = 'Dark'; $label = 'OFF'; $symbol = [string][char]0x25CB; $ascii = '[--]'
                $summary = 'Turned OFF.'
            }
            { $_ -in 'Starting', 'Resuming', 'Reset' } {
                $light = 'Green'; $blink = $true; $label = 'STARTING...'; $symbol = [string][char]0x21BB; $ascii = '[..]'
                $summary = 'Hyper-V is starting this VM.'
            }
            { $_ -in 'Saving', 'Pausing', 'FastSaving' } {
                $light = 'Yellow'; $blink = $true; $label = 'SAVING...'; $symbol = [string][char]0x21BB; $ascii = '[..]'
                $summary = 'Hyper-V is hibernating this VM.'
            }
            'Stopping' {
                $light = 'Dark'; $blink = $true; $label = 'STOPPING...'; $symbol = [string][char]0x21BB; $ascii = '[..]'
                $summary = 'Hyper-V is shutting this VM down.'
            }
            default {
                $summary = "Hyper-V reports an unusual state: $state."
            }
        }
    }
    $up = (-not $critical) -and $Vm.Exists -and ($state -in 'Running', 'Starting', 'Resuming', 'Reset')
    return New-VmsHealthObject -Role $Role -Name $Name -HostAddress $HostAddress -Exists $Vm.Exists -State $state -Critical $critical `
        -Status $Vm.Status -Uptime $Vm.UptimeSeconds -Heartbeat $hb -Responsive $responsive -Light $light -Blink $blink -Label $label `
        -Symbol $symbol -Ascii $ascii -Summary $summary -Booting $booting -IsUp $up -IsLocal $true
}

function New-VmsUnreachableHealth {
    <# The other server's VM when we cannot ask about it. #>
    param([string]$Role, [bool]$HostPing, [string]$Problem)
    $vc = Get-VmsVmConfig $Role
    $sentence = if ($HostPing) {
        "Cannot see this VM: server $($vc.Host) answers ping, but VM Switcher on it is not answering ($Problem)."
    } else {
        "Cannot see this VM: server $($vc.Host) does not answer at all (no ping, no VM Switcher). It may be down or its network is cut."
    }
    return New-VmsHealthObject -Role $Role -Name $vc.Name -HostAddress $vc.Host -Exists $true -State 'Unreachable' -Critical $false -Status '' `
        -Uptime 0 -Heartbeat '' -Responsive $false -Light 'Grey' -Blink $false -Label 'UNREACHABLE' -Symbol '?' -Ascii '[??]' `
        -Summary $sentence -Booting $false -IsUp $false -IsLocal $false -Reachable $false -HostPing $HostPing -PeerProblem $Problem
}

function ConvertFrom-VmsWireHealth($W, [string]$Role) {
    <# Health object received from the other server -> full local health object. #>
    $vc = Get-VmsVmConfig $Role
    return New-VmsHealthObject -Role $Role -Name ([string](Get-VmsProp $W 'Name' $vc.Name)) -HostAddress $vc.Host `
        -Exists (Get-VmsProp $W 'Exists' $false) -State (Get-VmsProp $W 'State' 'Unknown') -Critical (Get-VmsProp $W 'Critical' $false) `
        -Status (Get-VmsProp $W 'Status' '') -Uptime (Get-VmsProp $W 'UptimeSeconds' 0) -Heartbeat (Get-VmsProp $W 'Heartbeat' '') `
        -Responsive (Get-VmsProp $W 'PingOk' $false) -Light (Get-VmsProp $W 'Light' 'Grey') -Blink (Get-VmsProp $W 'Blink' $false) `
        -Label (Get-VmsProp $W 'ShortLabel' 'ERROR') -Symbol (Get-VmsProp $W 'Symbol' '?') -Ascii (Get-VmsProp $W 'Ascii' '[??]') `
        -Summary (Get-VmsProp $W 'Summary' '') -Booting (Get-VmsProp $W 'Booting' $false) -IsUp (Get-VmsProp $W 'IsUp' $false) `
        -IsLocal $false -Reachable $true -HostPing $true
}

function Get-VmsLocalHealth([ValidateSet('Primary', 'Secondary')][string]$Role) {
    $cfg = Get-VmsConfig
    $vc = $cfg.$Role
    $vm = Get-VmsProviderVm $vc.Name
    return ConvertTo-VmsHealth -Role $Role -Name $vc.Name -HostAddress $vc.Host -Vm $vm -BootGraceSeconds ([int]$cfg.BootGraceSeconds)
}

function Get-VmsPeerView {
    <#
      Asks the other server's VM Switcher for its status, and pings the other server once.
      Returns: Address, AppOk, HostPing, Problem, Status (raw /status payload or $null).
    #>
    $addr = Get-VmsPeerAddress
    $view = [pscustomobject]@{ Address = $addr; AppOk = $false; HostPing = $false; Problem = ''; Status = $null }
    if (-not $addr) { $view.Problem = 'no other server configured'; return $view }
    try {
        $view.Status = Invoke-VmsPeer -Method GET -Path '/vms/status'
        $view.AppOk = $true; $view.HostPing = $true
    } catch {
        $view.Problem = $_.Exception.Message
        $view.HostPing = Test-VmsHostPing $addr
    }
    return $view
}

function Get-VmsHealth([ValidateSet('Primary', 'Secondary')][string]$Role, $PeerView = $null) {
    <# Health of either VM: asked from local Hyper-V, or from the other server's VM Switcher. #>
    if (Test-VmsRoleIsLocal $Role) { return Get-VmsLocalHealth $Role }
    if (-not $PeerView) { $PeerView = Get-VmsPeerView }
    if ($PeerView.AppOk) {
        $w = Get-VmsProp $PeerView.Status 'Health'
        if ($w -and (Get-VmsProp $w 'Role') -eq $Role) { return ConvertFrom-VmsWireHealth $w $Role }
        return New-VmsUnreachableHealth -Role $Role -HostPing $true -Problem 'the other server does not hold this VM; check the VM names in settings'
    }
    return New-VmsUnreachableHealth -Role $Role -HostPing $PeerView.HostPing -Problem $PeerView.Problem
}

function Get-VmsSnapshot {
    $lr = Get-VmsLocalRole
    $peer = $null
    if ($lr -in 'Primary', 'Secondary') { $peer = Get-VmsPeerView }
    $p = Get-VmsHealth Primary $peer
    $s = Get-VmsHealth Secondary $peer
    $handoff = $null
    if (Test-VmsKeepsHandoffs) { try { $handoff = Get-VmsOpenHandoffInfo } catch { } }
    elseif ($peer -and $peer.AppOk) { $handoff = Get-VmsProp $peer.Status 'OpenHandoff' }
    return [pscustomobject]@{ Primary = $p; Secondary = $s; LocalRole = $lr; Peer = $peer; OpenHandoff = $handoff; Time = Get-Date }
}

function Set-VmsStatus($Health) {
    [void](Get-VmsDb).Execute('INSERT OR REPLACE INTO status(role,vm_name,light,blink,label,state,ping_ok,ping_ms,uptime_s,heartbeat,summary,updated_ts) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
        @($Health.Role, $Health.Name, $Health.Light, $Health.Blink, $Health.ShortLabel, $Health.State, $Health.PingOk, $null,
            $Health.UptimeSeconds, $Health.Heartbeat, $Health.Summary, (Format-VmsTs $Health.Time)))
}

# ---------------------------------------------------------------------------
# Peer protocol: HTTP + HMAC-SHA256 with a shared key typed into both installers
# ---------------------------------------------------------------------------

function Protect-VmsSecret([string]$Plain) {
    Add-Type -AssemblyName System.Security
    $b = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Plain), $null, 'LocalMachine')
    return [Convert]::ToBase64String($b)
}

function Get-VmsSharedKeyBytes {
    $cfg = Get-VmsConfig
    if ($env:VMSWITCHER_KEY) { return [Text.Encoding]::UTF8.GetBytes($env:VMSWITCHER_KEY) }
    if ($cfg.SharedKeyProtected) {
        Add-Type -AssemblyName System.Security
        return [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$cfg.SharedKeyProtected), $null, 'LocalMachine')
    }
    if ($cfg.SharedKey) { return [Text.Encoding]::UTF8.GetBytes([string]$cfg.SharedKey) }
    throw 'no shared key is set (run the installer on both servers with the same key)'
}

function Get-VmsSignature([byte[]]$Key, [string]$Method, [string]$Path, [string]$Ts, [string]$Nonce, [string]$Body) {
    $h = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    try {
        $msg = [Text.Encoding]::UTF8.GetBytes(($Method.ToUpper(), $Path, $Ts, $Nonce, $Body) -join "`n")
        return [Convert]::ToBase64String($h.ComputeHash($msg))
    } finally { $h.Dispose() }
}

function Get-VmsUnixTime { return [long]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds }

function Invoke-VmsPeer {
    <# Signed request to the other server's VM Switcher. Throws a readable error when it fails. #>
    param([ValidateSet('GET', 'POST')][string]$Method = 'GET', [string]$Path, $Body = $null, [int]$TimeoutMs = 0, [string]$KeyOverride = '')
    $cfg = Get-VmsConfig
    if (Test-VmsSimNetworkCut) { throw 'network cut (fire drill)' }
    $addr = Get-VmsPeerAddress
    if (-not $addr) { throw 'no other server configured' }
    if ($TimeoutMs -le 0) { $TimeoutMs = [int]$cfg.PeerTimeoutMs }
    $key = if ($KeyOverride) { [Text.Encoding]::UTF8.GetBytes($KeyOverride) } else { Get-VmsSharedKeyBytes }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 6 -Compress } else { '' }
    $ts = [string](Get-VmsUnixTime)
    $nonce = [guid]::NewGuid().ToString('N')
    $sig = Get-VmsSignature $key $Method $Path $ts $nonce $json
    $req = [Net.HttpWebRequest]::Create("http://${addr}:$([int]$cfg.PeerPort)$Path")
    $req.Method = $Method
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.KeepAlive = $false
    $req.Proxy = $null                       # never send LAN traffic to a proxy
    $req.Headers.Add('X-Vms-Ts', $ts)
    $req.Headers.Add('X-Vms-Nonce', $nonce)
    $req.Headers.Add('X-Vms-Sig', $sig)
    $req.Headers.Add('X-Vms-From', [string](Get-VmsLocalRole))
    try {
        if ($Method -eq 'POST') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $req.ContentType = 'application/json; charset=utf-8'
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        }
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r -and [int]$r.StatusCode -eq 401) { throw 'the other server rejected us: the shared keys do not match (or the clocks differ by more than 5 minutes)' }
        if ($r) { throw "the other server answered HTTP $([int]$r.StatusCode)" }
        throw ($_.Exception.Message)
    }
    try {
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close()
    } finally { $resp.Close() }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-VmsNonceCache {
    # Shared by all runspaces in this process (handlers run in parallel runspaces).
    $c = [AppDomain]::CurrentDomain.GetData('VMSwitcher.Nonces')
    if (-not $c) { $c = [hashtable]::Synchronized(@{}); [AppDomain]::CurrentDomain.SetData('VMSwitcher.Nonces', $c) }
    return $c
}

function Test-VmsPeerSignature {
    param([string]$Method, [string]$Path, [hashtable]$Headers, [string]$Body)
    $ts = [string]$Headers['x-vms-ts']; $nonce = [string]$Headers['x-vms-nonce']; $sig = [string]$Headers['x-vms-sig']
    if (-not $ts -or -not $nonce -or -not $sig) { return 'missing signature' }
    $skew = [math]::Abs((Get-VmsUnixTime) - [long]$ts)
    if ($skew -gt 300) { return "clock difference of $skew s (max 300)" }
    try { $key = Get-VmsSharedKeyBytes } catch { return $_.Exception.Message }
    $expected = Get-VmsSignature $key $Method $Path $ts $nonce $Body
    if ($expected -ne $sig) { return 'wrong shared key' }
    $cache = Get-VmsNonceCache
    if ($cache.ContainsKey($nonce)) { return 'replayed request' }
    $cache[$nonce] = Get-Date
    if ($cache.Count -gt 5000) {
        $old = @($cache.Keys | Where-Object { ((Get-Date) - $cache[$_]).TotalSeconds -gt 600 })
        foreach ($k in $old) { $cache.Remove($k) }
    }
    return ''
}

function Read-VmsHttpRequest([Net.Sockets.TcpClient]$Client) {
    <# Minimal HTTP/1.1 request reader (no http.sys, so no URL reservations are needed). #>
    $Client.ReceiveTimeout = 5000
    $stream = $Client.GetStream()
    $buf = New-Object byte[] 8192
    $ms = New-Object IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt 65536) { return $null }
        $all = $ms.ToArray()
        for ($i = 3; $i -lt $all.Length; $i++) {
            if ($all[$i - 3] -eq 13 -and $all[$i - 2] -eq 10 -and $all[$i - 1] -eq 13 -and $all[$i] -eq 10) { $headerEnd = $i + 1; break }
        }
    }
    $all = $ms.ToArray()
    $head = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $head -split "`r`n"
    $first = $lines[0] -split ' '
    if ($first.Count -lt 2) { return $null }
    $headers = @{}
    foreach ($l in $lines[1..($lines.Count - 1)]) {
        $ix = $l.IndexOf(':')
        if ($ix -gt 0) { $headers[$l.Substring(0, $ix).Trim().ToLower()] = $l.Substring($ix + 1).Trim() }
    }
    $len = 0
    if ($headers.ContainsKey('content-length')) { $len = [int]$headers['content-length'] }
    if ($len -gt 1048576) { return $null }
    $body = New-Object IO.MemoryStream
    $have = $all.Length - $headerEnd
    if ($have -gt 0) { $body.Write($all, $headerEnd, $have) }
    while ($body.Length -lt $len) {
        $n = $stream.Read($buf, 0, [math]::Min($buf.Length, $len - $body.Length))
        if ($n -le 0) { break }
        $body.Write($buf, 0, $n)
    }
    return @{ Method = $first[0].ToUpper(); Path = $first[1]; Headers = $headers; Body = [Text.Encoding]::UTF8.GetString($body.ToArray()); Stream = $stream }
}

function Write-VmsHttpResponse($Stream, [int]$Code, $Object) {
    $text = if ($null -ne $Object) { $Object | ConvertTo-Json -Depth 6 -Compress } else { '{}' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 404 = 'Not Found'; 500 = 'Internal Server Error' }[$Code]
    $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Code $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function ConvertTo-VmsWireRows($Table) {
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $Table.Rows) {
        $o = [ordered]@{}
        foreach ($c in $Table.Columns) { $v = $r[$c.ColumnName]; if ($v -is [DBNull]) { $v = $null }; $o[$c.ColumnName] = $v }
        [void]$out.Add([pscustomobject]$o)
    }
    return , $out.ToArray()
}

function Get-VmsLocalStatusPayload {
    <# What this server tells the other one every 3 seconds. #>
    $lr = Get-VmsLocalRole
    $health = $null
    if ($lr -in 'Primary', 'Secondary') { $health = Get-VmsLocalHealth $lr | Select-Object -Property * -ExcludeProperty Time }
    $row = Get-VmsWatchdogRow
    $wd = $null
    if ($row) { $wd = [pscustomobject]@{ Mode = $row.Mode; Alive = $row.Alive; Message = $row.Message } }
    $handoff = $null
    if (Test-VmsKeepsHandoffs) { $handoff = Get-VmsOpenHandoffInfo }
    return [pscustomobject]@{
        LocalRole = $lr; Server = $env:COMPUTERNAME; Health = $health; Watchdog = $wd
        Maintenance = ($null -ne (Get-VmsIntent 'maintenance')); PlannedStop = ($null -ne (Get-VmsIntent 'planned_stop'))
        OpenHandoff = $handoff; Time = (Format-VmsTs (Get-Date)); Version = '2.0.0'
    }
}

function Invoke-VmsPeerConnection([Net.Sockets.TcpClient]$Client) {
    <# Handles one request from the other server's VM Switcher. Runs in a background runspace of the watchdog. #>
    try {
        if (Test-VmsSimNetworkCut) { return }        # fire drill: behave as if the network is cut
        $req = Read-VmsHttpRequest $Client
        if (-not $req) { return }
        $bad = Test-VmsPeerSignature -Method $req.Method -Path $req.Path -Headers $req.Headers -Body $req.Body
        if ($bad) {
            Write-VmsHttpResponse $req.Stream 401 @{ Error = $bad }
            $from = '?'
            try { $from = $Client.Client.RemoteEndPoint.ToString() } catch { }
            Write-VmsEvent -Severity Warning -Action 'PeerRejected' -Result 'REFUSED' -Message "Refused a request from $from : $bad." -Alert -Title 'Rejected a request from the other server'
            return
        }
        $body = $null
        if ($req.Body) { $body = $req.Body | ConvertFrom-Json }
        $path = $req.Path.Split('?')[0]
        $query = @{}
        if ($req.Path.Contains('?')) { foreach ($kv in $req.Path.Split('?')[1].Split('&')) { $p = $kv.Split('='); if ($p.Count -eq 2) { $query[$p[0]] = [Uri]::UnescapeDataString($p[1]) } } }
        switch ("$($req.Method) $path") {
            'GET /vms/status' { Write-VmsHttpResponse $req.Stream 200 (Get-VmsLocalStatusPayload) }
            'POST /vms/command' {
                $role = [string](Get-VmsProp $body 'Role'); $op = [string](Get-VmsProp $body 'Op')
                if (-not (Test-VmsRoleIsLocal $role) -or $op -notin 'Start', 'Save', 'Stop', 'Restart', 'TurnOff', 'Pause') {
                    Write-VmsHttpResponse $req.Stream 400 (New-VmsResult 'REFUSED' "This server does not hold the $role VM.")
                    return
                }
                $by = [string](Get-VmsProp $body 'By' 'the other server')
                $r = Invoke-VmsVmOp -Role $role -Op $op -Reason ([string](Get-VmsProp $body 'Reason' '')) -RequestedBy $by
                Write-VmsHttpResponse $req.Stream 200 $r
            }
            'POST /vms/intent' {
                $name = [string](Get-VmsProp $body 'Name')
                if ($name -notin 'maintenance', 'planned_stop', 'adopt_handoff', 'failback') { Write-VmsHttpResponse $req.Stream 400 @{ Error = 'unknown intent' }; return }
                if (Get-VmsProp $body 'Clear' $false) { Clear-VmsIntent $name }
                else { Set-VmsIntent -Name $name -Value ([string](Get-VmsProp $body 'Value' '1')) -ExpiresSeconds ([int](Get-VmsProp $body 'ExpiresSeconds' 0)) -SetBy ([string](Get-VmsProp $body 'SetBy' 'other server')) }
                Write-VmsHttpResponse $req.Stream 200 (New-VmsResult 'OK' 'saved')
            }
            'POST /vms/sim' {
                if ((Get-VmsConfig).Provider -ne 'Simulated') { Write-VmsHttpResponse $req.Stream 400 @{ Error = 'demo mode only' }; return }
                $role = [string](Get-VmsProp $body 'Role')
                $pp = @{ Role = $role }
                $st = Get-VmsProp $body 'State'; if ($st) { $pp.State = [string]$st }
                $pk = Get-VmsProp $body 'PingOk'; if ($null -ne $pk) { $pp.PingOk = [bool]$pk }
                $ut = Get-VmsProp $body 'UptimeSeconds'; if ($null -ne $ut) { $pp.UptimeSeconds = [int]$ut }
                Set-VmsSimVm @pp
                Write-VmsHttpResponse $req.Stream 200 (New-VmsResult 'OK' 'done')
            }
            'GET /vms/events' {
                $limit = if ($query.ContainsKey('limit')) { [int]$query['limit'] } else { 150 }
                Write-VmsHttpResponse $req.Stream 200 @{ Rows = (ConvertTo-VmsWireRows (Get-VmsEvents $limit)) }
            }
            'GET /vms/handoffs' { Write-VmsHttpResponse $req.Stream 200 @{ Rows = (ConvertTo-VmsWireRows (Get-VmsHandoffs 100)) } }
            default { Write-VmsHttpResponse $req.Stream 404 @{ Error = 'unknown path' } }
        }
    } catch {
        try { if ($req) { Write-VmsHttpResponse $req.Stream 500 @{ Error = $_.Exception.Message } } } catch { }
    } finally {
        try { $Client.Close() } catch { }
    }
}

# ---------------------------------------------------------------------------
# Watchdog state (persisted so a service restart remembers an active failover)
# ---------------------------------------------------------------------------

function New-VmsWatchdogState {
    return @{
        Mode = 'Normal'; Misses = 0; DownSince = $null; HealthySince = $null; LastRetry = $null
        HandoffId = $null; Standin = $false; SecondaryUpLogged = $false
        Flags = @{}
    }
}

function ConvertTo-VmsStateJson([hashtable]$State) {
    $copy = @{}
    foreach ($k in $State.Keys) {
        $v = $State[$k]
        if ($v -is [datetime]) { $v = 'ts:' + (Format-VmsTs $v) }
        $copy[$k] = $v
    }
    return ($copy | ConvertTo-Json -Depth 4 -Compress)
}

function ConvertFrom-VmsStateJson([string]$Json) {
    $st = New-VmsWatchdogState
    if ([string]::IsNullOrWhiteSpace($Json)) { return $st }
    $o = $Json | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [string] -and $v.StartsWith('ts:')) { $v = ConvertFrom-VmsTs $v.Substring(3) }
        if ($p.Name -eq 'Flags') {
            $f = @{}
            if ($v) { foreach ($fp in $v.PSObject.Properties) { $f[$fp.Name] = $fp.Value } }
            $v = $f
        }
        $st[$p.Name] = $v
    }
    return $st
}

function Get-VmsWatchdogRow {
    $t = (Get-VmsDb).Query('SELECT mode,message,state_json,last_tick_ts,started_ts,pid FROM watchdog WHERE id = 1')
    if ($t.Rows.Count -eq 0) { return $null }
    $r = $t.Rows[0]
    $last = ConvertFrom-VmsTs $r.last_tick_ts
    $alive = $false
    if ($last) { $alive = ((Get-Date) - $last).TotalSeconds -lt 15 }
    return [pscustomobject]@{
        Mode = [string]$r.mode; Message = [string]$r.message; State = (ConvertFrom-VmsStateJson ([string]$r.state_json))
        LastTick = $last; Started = (ConvertFrom-VmsTs $r.started_ts); Pid = $r.pid; Alive = $alive
    }
}

function Save-VmsWatchdogRow([hashtable]$State, [string]$Message, [datetime]$Started) {
    [void](Get-VmsDb).Execute('INSERT OR REPLACE INTO watchdog(id,mode,message,state_json,last_tick_ts,started_ts,pid) VALUES (1,?,?,?,?,?,?)',
        @($State.Mode, $Message, (ConvertTo-VmsStateJson $State), (Format-VmsTs (Get-Date)), (Format-VmsTs $Started), $PID))
}

# ---------------------------------------------------------------------------
# Failover brain (pure: no side effects, fully unit-testable)
# ---------------------------------------------------------------------------

function Get-VmsWatchdogDecision {
    <#
      Inputs : health of both VMs (local or reported by the other server), previous state, time, config, intents.
      Output : new state + actions for the executor + plain-English explanation lines.
      Action types: StartSecondary, ShutdownSecondary, TurnOffSecondary, TurnOffPrimary, HoldPrimary, ReleasePrimary, BeginFailback, EndFailback, OpenHandoff, MarkSecondaryUp, CloseHandoff, ClearPlanned, AdoptHandoff, Event
      Both servers run this. VM actions are executed by the server that holds the VM (the "lock" is there);
      a repeated request is a harmless no-op.
    #>
    param(
        [Parameter(Mandatory)]$Primary,
        [Parameter(Mandatory)]$Secondary,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)]$Config,
        [bool]$Maintenance = $false,
        [bool]$PlannedStop = $false,
        $AdoptHandoffId = $null,
        [int]$HostUptimeSeconds = [int]::MaxValue,
        [bool]$FailbackActive = $false
    )
    $st = @{}
    foreach ($k in $State.Keys) { $st[$k] = $State[$k] }
    $st.Flags = @{}
    foreach ($k in $State.Flags.Keys) { $st.Flags[$k] = $State.Flags[$k] }
    $actions = New-Object System.Collections.ArrayList
    $explain = New-Object System.Collections.ArrayList
    $interval = [int]$Config.CheckIntervalSeconds
    $missLimit = [int]$Config.MissedPingsForFailover
    $p = $Primary; $s = $Secondary

    function Add-Act([hashtable]$a) { [void]$actions.Add($a) }
    function Add-Event([string]$Sev, [string]$Act, [string]$Msg, [bool]$Alert = $false, [string]$Title = '', [string]$Role = '', [string]$Detail = '') {
        [void]$actions.Add(@{ Type = 'Event'; Severity = $Sev; Action = $Act; Message = $Msg; Alert = $Alert; Title = $Title; Role = $Role; Detail = $Detail })
    }

    # --- planned switchover started from the GUI/terminal: adopt it ---
    if ($null -ne $AdoptHandoffId -and $st.Mode -eq 'Normal') {
        $st.Mode = 'FailedOver'; $st.HandoffId = [long]$AdoptHandoffId; $st.Standin = $true
        $st.SecondaryUpLogged = $false; $st.HealthySince = $null; $st.Misses = 0
        Add-Act @{ Type = 'AdoptHandoff' }
        [void]$explain.Add('A planned switchover is in progress; the watchdog now looks after it.')
    }

    # --- the other server's view: warn once when we cannot see a VM but its server still pings ---
    foreach ($h in @($p, $s)) {
        $flag = "Blind$($h.Role)"
        if (-not $h.Reachable -and $h.HostPing) {
            if (-not $st.Flags[$flag]) {
                Add-Event 'Warning' 'PeerAppDown' ("Cannot see the $($h.Role): server $($h.Host) answers ping but VM Switcher on it is not answering. No automatic action is taken for this. Check the 'VM Switcher Watchdog' service on $($h.Host).") $true "VM Switcher on $($h.Host) is not answering" $h.Role
                $st.Flags[$flag] = $true
            }
            [void]$explain.Add("VM Switcher on $($h.Host) is not answering, so the $($h.Role) cannot be seen.")
        } elseif ($h.Reachable) { $st.Flags.Remove($flag) }
    }
    if (-not $s.Reachable -and -not $s.HostPing) {
        if (-not $st.Flags['SecondaryServerDown']) {
            Add-Event 'Warning' 'BackupUnreachable' "The backup server $($s.Host) cannot be reached. If the Primary fails now, there is NO automatic failover." $true 'Backup server unreachable' 'Secondary'
            $st.Flags['SecondaryServerDown'] = $true
        }
    } elseif ($s.Reachable) { $st.Flags.Remove('SecondaryServerDown') }

    # --- count misses for the Primary ---
    #   local/visible: heartbeat lost on a running VM past its boot time
    #   invisible:     the Primary's server does not answer ping AND its app is silent (total silence)
    if (($FailbackActive -or $st.Mode -eq 'FailingBack') -and $p.Reachable) { $st.Misses = 0 }
    elseif (-not $p.Reachable) {
        if (-not $p.HostPing) { $st.Misses = [int]$st.Misses + 1 } else { $st.Misses = 0 }
    } elseif ($p.Exists -and $p.State -eq 'Running' -and -not $p.Booting -and -not $p.Critical) {
        if ($p.PingOk) { $st.Misses = 0 } else { $st.Misses = [int]$st.Misses + 1 }
    } else { $st.Misses = 0 }

    # --- is the Primary failed? ---
    $fail = $null
    $expectedOff = $false
    $silence = $false
    $hostGrace = [int]$Config.HostBootGraceSeconds
    $hostStarting = $HostUptimeSeconds -lt $hostGrace
    if ($hostStarting -and $st.Mode -eq 'Normal' -and $p.Reachable -and $p.Exists -and -not $p.Critical -and $p.State -in 'Off', 'Saved', 'Starting') {
        [void]$explain.Add("This server started $(Format-VmsDuration $HostUptimeSeconds) ago. Waiting up to $(Format-VmsDuration $hostGrace) for Hyper-V to start the Primary on its own before any failover.")
        $expectedOff = $true
    }
    if (-not $p.Reachable) {
        if ($st.Misses -ge $missLimit) {
            $fail = "the Primary's server $($p.Host) went completely silent (no ping and no VM Switcher for $($st.Misses) checks, about $($st.Misses * $interval) s)"
            $silence = $true
        }
    }
    elseif (-not $p.Exists) { $fail = "the Primary VM '$($p.Name)' was not found in Hyper-V on $($p.Host)" }
    elseif ($p.Critical) { $fail = "Hyper-V reports a critical error on the Primary (state: $($p.State))" }
    elseif ($p.State -eq 'Off' -and -not ($PlannedStop -or $expectedOff)) { $fail = 'the Primary turned OFF unexpectedly' }
    elseif ($p.State -in 'Saved', 'Paused', 'FastSaved' -and -not ($PlannedStop -or $expectedOff)) { $fail = 'the Primary was suspended outside VM Switcher' }
    elseif ($st.Misses -ge $missLimit) { $fail = "the Primary stopped reporting its heartbeat ($($st.Misses) missed checks in a row, about $($st.Misses * $interval) s)" }

    $pHealthy = [bool]$p.IsHealthy
    $sUp = [bool]$s.IsUp
    $sHealthy = [bool]$s.IsHealthy
    # Both VMs use ONE shared IP address, so they must never be ON together.
    # A VM counts as "on the network" from the moment Hyper-V starts it (before Windows inside it claims the address).
    # While a failback is in progress, a Primary that VM Switcher holds PAUSED also counts as "on" (it resumes soon).
    $pOn = [bool]($p.Reachable -and $p.Exists -and ($p.IsUp -or $p.State -like 'Running*' -or ($FailbackActive -and $p.State -eq 'Paused')))
    $sOn = [bool]($s.Reachable -and $s.Exists -and ($s.IsUp -or $s.State -like 'Running*' -or $s.State -eq 'Stopping'))
    # "Early" = the Primary is still booting: hold it PAUSED (safe, nothing lost) until the Secondary has shut down cleanly.
    $pEarly = [bool]($p.Reachable -and ($p.State -in 'Starting', 'Resuming', 'Reset', 'Paused' -or $p.Booting))
    $holdLimit = [int]$Config.ShutdownTimeoutSeconds + 60

    function Start-Failback([string]$Why, [string]$Text) {
        # Safe failback: (1) hold the booting Primary paused, (2) shut the Secondary down cleanly, (3) resume the Primary.
        if ($pEarly) { Add-Act @{ Type = 'HoldPrimary'; Reason = $Why }; $st.Flags['HeldPrimary'] = $true }
        Add-Act @{ Type = 'ShutdownSecondary'; Reason = $Why }
        Add-Act @{ Type = 'BeginFailback' }
        $st.Mode = 'FailingBack'; $st.HoldSince = $Now; $st.LastStopRequest = $Now
        $how = if ($pEarly) { 'The Primary is held PAUSED (nothing is lost) so it cannot use the shared IP address yet. ' } else { '' }
        Add-Event 'Info' 'FailbackStart' ("$Text $($how)The Secondary is shutting down cleanly (its data is saved); the Primary continues the moment the Secondary is OFF.") $true 'Switching back to the Primary' 'Secondary'
        [void]$explain.Add('Failback started: the Secondary is shutting down cleanly' + $(if ($pEarly) { ' while the Primary is held paused.' } else { '.' }))
    }

    if ($st.Misses -gt 0 -and $st.Misses -lt $missLimit -and $st.Mode -ne 'FailingBack') {
        $what = if ($p.Reachable) { 'heartbeat checks' } else { "checks of server $($p.Host)" }
        [void]$explain.Add("Primary missed $($st.Misses) of $missLimit $what. Failover happens at $missLimit in a row.")
    }

    # The other server started a failback: follow it, so a held (paused) Primary is not mistaken for a failure.
    if ($FailbackActive -and $st.Mode -ne 'FailingBack' -and $p.Reachable -and $s.Reachable) {
        $st.Mode = 'FailingBack'; $st.HoldSince = $Now; $st.LastStopRequest = $Now
        if ($p.State -eq 'Paused') { $st.Flags['HeldPrimary'] = $true }
        [void]$explain.Add('A failback started by the other server is in progress; following it.')
    }

    if ($st.Mode -eq 'FailingBack' -and -not $p.Reachable) {
        # Lost the Primary's server in the middle of a failback: stop following it, normal failover rules apply again.
        Add-Act @{ Type = 'EndFailback' }
        Add-Event 'Warning' 'FailbackAborted' "Lost contact with the Primary's server $($p.Host) during the failback. Normal failover rules apply again." $true 'Failback interrupted' 'Primary'
        $st = (New-VmsWatchdogState); $st.Mode = 'Normal'
        [void]$explain.Add('Failback interrupted: the Primary cannot be seen.')
    }
    if ($st.Mode -eq 'FailingBack') {
        if (-not $st.HoldSince) { $st.HoldSince = $Now }
        $took = ($Now - $st.HoldSince).TotalSeconds
        $sOff = [bool]($s.Reachable -and (-not $s.Exists -or $s.State -eq 'Off'))
        if ($sOff) {
            $held = [bool]($st.Flags['HeldPrimary'] -or ($p.Reachable -and $p.State -eq 'Paused'))
            if ($held) { Add-Act @{ Type = 'ReleasePrimary'; Reason = 'the Secondary is OFF' } }
            Add-Act @{ Type = 'CloseHandoff'; By = 'Watchdog (automatic failback)' }
            Add-Act @{ Type = 'EndFailback' }
            $tail = if ($held) { ' The Primary was held paused meanwhile and now continues starting.' } else { '' }
            Add-Event 'Info' 'Failback' ("FAILBACK complete: the Secondary shut down cleanly in $(Format-VmsDuration $took) (no data lost).$tail The two VMs never used the shared IP address at the same time.") $true 'Back to the Primary' 'Secondary'
            [void]$explain.Add('Failback complete. Back to normal.')
            $st = (New-VmsWatchdogState); $st.Mode = 'Normal'
        } elseif (-not $s.Reachable) {
            [void]$explain.Add("Failback in progress, but the Secondary's server cannot be reached right now.")
        } else {
            if ($took -ge $holdLimit) {
                if (-not $st.Flags['FailbackSlow']) {
                    Add-Event 'Critical' 'FailbackStuck' ("The Secondary has not turned OFF after $(Format-VmsDuration $took). The Primary stays held so the two VMs do not use the shared IP address together. Check the Secondary in Hyper-V Manager, or press 1 to try again.") $true 'Failback is stuck' 'Secondary'
                    $st.Flags['FailbackSlow'] = $true
                }
            }
            if ($st.Flags['HeldPrimary'] -and $p.Reachable -and $p.State -ne 'Paused' -and ($p.IsUp -or $p.State -like 'Running*')) {
                # Hyper-V may refuse to pause a VM in its first moments of "Starting": keep trying every check.
                Add-Act @{ Type = 'HoldPrimary'; Reason = 'repeat: the Primary must stay paused until the Secondary is OFF' }
            }
            if ($took -ge $holdLimit) { }
            elseif ($s.State -like 'Running*' -and (-not $st.LastStopRequest -or ($Now - $st.LastStopRequest).TotalSeconds -ge 20)) {
                Add-Act @{ Type = 'ShutdownSecondary'; Reason = 'repeat: failback in progress' }     # in case the first request was lost
                $st.LastStopRequest = $Now
            }
            [void]$explain.Add("Failback in progress ($(Format-VmsDuration $took)): the Secondary is shutting down cleanly" + $(if ($st.Flags['HeldPrimary']) { '; the Primary is held paused until then.' } else { '.' }))
        }
    }
    elseif ($st.Mode -eq 'Normal') {
        if ($fail) {
            if (-not $st.DownSince) {
                $back = 0
                if ($st.Misses -ge $missLimit) { $back = ($st.Misses - 1) * $interval }
                $st.DownSince = $Now.AddSeconds(-$back)
            }
            if ($Maintenance) {
                [void]$explain.Add("Primary is down ($fail) but auto-failover is PAUSED (maintenance mode), so nothing is done.")
                if (-not $st.Flags['MaintDownWarned']) {
                    Add-Event 'Warning' 'MaintenanceHold' ("Primary is down because $fail. Auto-failover is paused (maintenance mode), so the Secondary was NOT started.") $true 'Primary down (maintenance mode)' 'Primary'
                    $st.Flags['MaintDownWarned'] = $true
                }
            } else {
                $st.Mode = 'FailedOver'; $st.HealthySince = $null; $st.SecondaryUpLogged = $false; $st.LastRetry = $Now
                $st.Standin = -not $sUp
                if ($silence) { $st.Flags['SilenceFailover'] = $true }
                Add-Act @{ Type = 'OpenHandoff'; Reason = $fail; Down = $st.DownSince }
                if ($pOn) {
                    # A FROZEN Primary still holds the shared IP address and cannot shut down by itself (Windows inside
                    # it is hung, so there is nothing it could still save): power it off BEFORE the Secondary starts.
                    Add-Act @{ Type = 'TurnOffPrimary'; Reason = $fail }
                    [void]$explain.Add('Powering OFF the frozen Primary first, so the two VMs never use the shared IP address at the same time.')
                }
                if ($sUp) {
                    Add-Event 'Critical' 'Failover' ("FAILOVER: $fail. The Secondary was already ON, so it takes over now.") $true 'Failover: Primary is down' 'Primary'
                    [void]$explain.Add("Primary failed ($fail). Secondary is already ON and takes over.")
                } else {
                    Add-Event 'Critical' 'Failover' ("FAILOVER: $fail. Turning ON the Secondary now.") $true 'Failover: Primary is down' 'Primary'
                    Add-Act @{ Type = 'StartSecondary'; Reason = $fail }
                    [void]$explain.Add("Primary failed ($fail). Turning ON the Secondary now.")
                }
            }
        } else {
            $st.DownSince = $null
            if ($pHealthy) { $st.Flags.Remove('MaintDownWarned'); $st.Flags.Remove('PlannedOffLogged'); $st.Flags.Remove('BothOffWarned') }
            if ($pOn -and $sOn) {
                if ($Maintenance) {
                    if (-not $st.Flags['BothOnMaint']) {
                        Add-Event 'Critical' 'BothOn' 'BOTH VMs ARE ON and they share one IP address. Maintenance mode is ON, so VM Switcher does not act. Turn OFF one of them now (option 3 turns OFF the Secondary).' $true 'BOTH VMs ARE ON (IP conflict)'
                        $st.Flags['BothOnMaint'] = $true
                    }
                    [void]$explain.Add('Both VMs are ON (shared IP address) but maintenance mode is ON, so nothing is done.')
                } else {
                    Start-Failback 'both VMs were ON (shared IP address)' 'Both VMs were ON at the same time and they share one IP address.'
                }
            } else { $st.Flags.Remove('BothOnMaint') }
            if ($st.Mode -eq 'Normal') {
                if ($PlannedStop -and $pHealthy) { Add-Act @{ Type = 'ClearPlanned' } }
                if ($PlannedStop -and $p.Reachable -and $p.State -in 'Off', 'Saved', 'Paused') {
                    [void]$explain.Add('Primary is OFF on purpose (planned stop), so there is no failover.')
                    if (-not $st.Flags['PlannedOffLogged']) {
                        Add-Event 'Info' 'PlannedStopSeen' 'Primary is OFF as planned. No failover was done.' $false '' 'Primary'
                        $st.Flags['PlannedOffLogged'] = $true
                    }
                    if ($s.Reachable -and -not $sUp -and -not $s.Transitional -and -not $st.Flags['BothOffWarned']) {
                        Add-Event 'Warning' 'BothOff' 'Both VMs are OFF. Nobody is serving users until one of them is turned ON.' $true 'Both VMs are OFF'
                        $st.Flags['BothOffWarned'] = $true
                    }
                }
                if ($pHealthy -and $explain.Count -eq 0) { [void]$explain.Add('Primary is healthy and serving. Nothing to do.') }
                elseif ($p.Transitional -or $p.Booting) { [void]$explain.Add("Primary is $($p.ShortLabel.ToLower()). Waiting.") }
            }
        }
    } else {
        # ----- Mode FailedOver: Secondary is (supposed to be) serving -----
        if ($sHealthy -and -not $st.SecondaryUpLogged) {
            Add-Act @{ Type = 'MarkSecondaryUp' }
            $st.SecondaryUpLogged = $true
        }

        if ($pOn) {
            # The Primary is coming back.
            if ($sOn -or $s.Transitional) {
                if ($Maintenance) {
                    if (-not $st.Flags['BothOnMaint']) {
                        Add-Event 'Critical' 'BothOn' 'The Primary is ON again while the Secondary is ON, and they share one IP address. Maintenance mode is ON, so VM Switcher does not act. Turn OFF the Secondary now (option 3).' $true 'BOTH VMs ARE ON (IP conflict)'
                        $st.Flags['BothOnMaint'] = $true
                    }
                    [void]$explain.Add('Primary is back but maintenance mode is ON, so the Secondary is left ON.')
                } else {
                    $text = if ($st.Flags['SilenceFailover'] -and $pHealthy) { "Contact with the Primary's server $($p.Host) is back and the Primary is running." } else { "FAILBACK: the Primary is starting again ($(Get-VmsHealthWord $p))." }
                    Start-Failback 'automatic failback: the Primary is ON again' $text
                }
            } else {
                Add-Act @{ Type = 'CloseHandoff'; By = 'Primary back, Secondary already OFF' }
                Add-Event 'Info' 'FailoverEnded' 'The Primary is ON again and the Secondary is already OFF. Back to normal.' $false '' 'Primary'
                [void]$explain.Add('Primary is ON again and the Secondary is off. Back to normal.')
                $st = (New-VmsWatchdogState); $st.Mode = 'Normal'
            }
        } else {
            if (-not $sUp -and -not $s.Transitional) {
                if (-not $st.Flags['BothDownAlerted']) {
                    Add-Event 'Critical' 'BothDown' ("BOTH VMs ARE DOWN. Primary: $(Get-VmsHealthWord $p). Secondary: $(Get-VmsHealthWord $s) - $($s.Summary)") $true 'BOTH VMs ARE DOWN' 'Secondary'
                    $st.Flags['BothDownAlerted'] = $true
                }
                $retry = [int]$Config.BothDownRetrySeconds
                if (-not $Maintenance -and (-not $st.LastRetry -or ($Now - $st.LastRetry).TotalSeconds -ge $retry)) {
                    Add-Act @{ Type = 'StartSecondary'; Reason = 'retry while both VMs are down' }
                    $st.LastRetry = $Now
                    [void]$explain.Add('Both VMs are down. Trying again to turn ON the Secondary.')
                } else {
                    [void]$explain.Add("Both VMs are down. Next attempt to start the Secondary within $retry s.")
                }
            } elseif ($sUp) {
                $st.Flags.Remove('BothDownAlerted')
            }
            if ($sHealthy) { [void]$explain.Add('Failover active: the Secondary is serving while the Primary is down. When the Primary starts again it is held paused, the Secondary shuts down cleanly, then the Primary continues.') }
            elseif ($sUp) { [void]$explain.Add('Failover active: the Secondary is starting up.') }
        }
    }

    return [pscustomobject]@{ State = $st; Actions = $actions; Explain = $explain }
}

# ---------------------------------------------------------------------------
# VM operations: run here if the VM lives on this server, otherwise ask the other server
# ---------------------------------------------------------------------------

function New-VmsResult([string]$Result, [string]$Message) {
    return [pscustomobject]@{ Ok = ($Result -in 'OK', 'NOOP', 'INFO'); Result = $Result; Message = $Message }
}

function Get-VmsActionMutex {
    <#
      One machine-wide lock per server, shared by the watchdog (LocalSystem), the peer endpoint and the GUI/terminal.
      Explicit ACL so a lock created by SYSTEM can still be used by administrators, and vice versa.
    #>
    $name = 'Global\VMSwitcher.Action' + (Get-VmsInstanceSuffix)
    $sec = New-Object System.Security.AccessControl.MutexSecurity
    foreach ($sid in @([System.Security.Principal.WellKnownSidType]::LocalSystemSid, [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid)) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid, $null)
        $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($id, [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    $created = $false
    try { return (New-Object System.Threading.Mutex($false, $name, [ref]$created, $sec)) }
    catch {
        $rights = [System.Security.AccessControl.MutexRights]::Synchronize -bor [System.Security.AccessControl.MutexRights]::Modify
        return [System.Threading.Mutex]::OpenExisting($name, $rights)
    }
}

function Invoke-VmsLocked([scriptblock]$Body, [int]$WaitMs = 90000) {
    $m = Get-VmsActionMutex
    $got = $false
    try {
        try { $got = $m.WaitOne($WaitMs) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { return (New-VmsResult 'FAILED' 'Another VM action is still running on this server. Try again in a minute.') }
        return (& $Body)
    } finally {
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function Invoke-VmsVmOp {
    <#
      Start | Save | Stop | Restart one VM. Idempotent: asking twice is harmless (NOOP).
      Local VM: executed under this server's lock. Remote VM: sent to the other server, which uses ITS lock.
      The lock is held only around the local Hyper-V call, so the two servers can never deadlock each other.
    #>
    param([ValidateSet('Primary', 'Secondary')][string]$Role, [ValidateSet('Start', 'Save', 'Stop', 'Restart', 'TurnOff', 'Pause')][string]$Op, [string]$Reason = '', [string]$RequestedBy = '')
    if (Test-VmsRoleIsLocal $Role) {
        return Invoke-VmsLocked {
            $h = Get-VmsLocalHealth $Role
            if (-not $h.Exists) { return (New-VmsResult 'REFUSED' "The $Role VM '$($h.Name)' was not found in Hyper-V on this server.") }
            switch ($Op) {
                'Start' { if ($h.IsUp -and -not $h.IsFrozen) { return (New-VmsResult 'NOOP' "The $Role is already ON.") } ; if ($h.IsFrozen) { $Op = 'Restart' } }
                'Save' { if (-not $h.IsUp) { return (New-VmsResult 'NOOP' "The $Role is already $(Get-VmsHealthWord $h).") } }
                'Stop' {
                    if ($h.State -eq 'Stopping') { return (New-VmsResult 'NOOP' "The $Role is already shutting down.") }
                    if (-not $h.IsUp -and $h.State -notin 'Saved', 'Paused') { return (New-VmsResult 'NOOP' "The $Role is already $(Get-VmsHealthWord $h).") }
                }
                'Restart' { if (-not $h.IsUp) { $Op = 'Start' } }
                'TurnOff' { if ($h.State -eq 'Off') { return (New-VmsResult 'NOOP' "The $Role is already OFF.") } }
                'Pause' {
                    if ($h.State -eq 'Paused') { return (New-VmsResult 'NOOP' "The $Role is already paused.") }
                    if (-not ($h.IsUp -or $h.State -like 'Running*')) { return (New-VmsResult 'NOOP' "The $Role is not running.") }
                }
            }
            try {
                Invoke-VmsProviderOp $Op $h.Name
                if ($RequestedBy) {
                    Write-VmsEvent -Action "Peer$Op" -Result 'OK' -Role $Role -Actor $RequestedBy -Message ("Did '$Op' on the $Role at the request of $RequestedBy" + $(if ($Reason) { " ($Reason)." } else { '.' }))
                }
                return (New-VmsResult 'OK' "$Op done on the $Role.")
            } catch { return (New-VmsResult 'FAILED' "Hyper-V could not $($Op.ToLower()) the $Role : $($_.Exception.Message)") }
        }
    }
    $addr = Get-VmsPeerAddress
    try {
        $by = "$(Get-VmsActor) via $script:Source on $env:COMPUTERNAME"
        $r = Invoke-VmsPeer -Method POST -Path '/vms/command' -Body @{ Role = $Role; Op = $Op; Reason = $Reason; By = $by } -TimeoutMs ([int](Get-VmsConfig).PeerCommandTimeoutMs)
        return (New-VmsResult ([string](Get-VmsProp $r 'Result' 'FAILED')) ([string](Get-VmsProp $r 'Message' '')))
    } catch {
        return (New-VmsResult 'FAILED' "Could not reach VM Switcher on the $Role's server $addr : $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# Watchdog executor: one tick = snapshot, log changes, decide, act, persist
# ---------------------------------------------------------------------------

$script:HostBootTime = $null
function Get-VmsHostUptimeSeconds {
    <# Seconds since this Hyper-V server booted (cached; tests can override with VMSWITCHER_HOST_UPTIME). #>
    if ($env:VMSWITCHER_HOST_UPTIME) { return [int]$env:VMSWITCHER_HOST_UPTIME }
    if (-not $script:HostBootTime) {
        try { $script:HostBootTime = (Get-CimInstance Win32_OperatingSystem -Verbose:$false).LastBootUpTime }
        catch { $script:HostBootTime = [datetime]::MinValue }
    }
    $s = ((Get-Date) - $script:HostBootTime).TotalSeconds
    if ($s -gt [int]::MaxValue) { return [int]::MaxValue }
    return [int]$s
}

function Invoke-VmsWatchdogTick {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Previous,     # role -> last health, for change logging
        [datetime]$Now = (Get-Date),
        [datetime]$Started = (Get-Date)
    )
    $cfg = Get-VmsConfig
    $snap = Get-VmsSnapshot
    foreach ($h in @($snap.Primary, $snap.Secondary)) {
        Set-VmsStatus $h
        $old = $Previous[$h.Role]
        if ($old -and ($old.Light -ne $h.Light -or $old.State -ne $h.State -or $old.Blink -ne $h.Blink)) {
            Write-VmsTransition -Role $h.Role -FromLight $old.Light -ToLight $h.Light -FromState $old.State -ToState $h.State `
                -Message ("{0} changed from {1} to {2}. {3}" -f $h.Role, $old.ShortLabel, $h.ShortLabel, $h.Summary)
        }
        $Previous[$h.Role] = $h
    }

    $maint = $null -ne (Get-VmsIntent 'maintenance')
    $planned = $null -ne (Get-VmsIntent 'planned_stop')
    $adopt = Get-VmsIntent 'adopt_handoff'
    $adoptId = if ($adopt) { [long]$adopt.Value } else { $null }

    $failback = $null -ne (Get-VmsIntent 'failback')
    $d = Get-VmsWatchdogDecision -Primary $snap.Primary -Secondary $snap.Secondary -State $State -Now $Now -Config $cfg `
        -Maintenance $maint -PlannedStop $planned -AdoptHandoffId $adoptId -HostUptimeSeconds (Get-VmsHostUptimeSeconds) -FailbackActive $failback
    $st = $d.State
    $keeps = Test-VmsKeepsHandoffs

    # Speed first, safety always: hold/stop/start before any logging or history writing.
    $urgent = @{}
    foreach ($type in 'TurnOffPrimary', 'HoldPrimary', 'ShutdownSecondary', 'TurnOffSecondary', 'StartSecondary', 'ReleasePrimary') {
        $ua = $d.Actions | Where-Object { $_.Type -eq $type } | Select-Object -First 1
        if (-not $ua) { continue }
        switch ($type) {
            'TurnOffPrimary' { $urgent[$type] = Invoke-VmsVmOp -Role Primary -Op TurnOff -Reason $ua.Reason }
            'HoldPrimary' { $urgent[$type] = Invoke-VmsVmOp -Role Primary -Op Pause -Reason $ua.Reason }
            'ShutdownSecondary' { $urgent[$type] = Invoke-VmsVmOp -Role Secondary -Op Stop -Reason $ua.Reason }
            'TurnOffSecondary' { $urgent[$type] = Invoke-VmsVmOp -Role Secondary -Op TurnOff -Reason $ua.Reason }
            'StartSecondary' {
                if ($urgent.ContainsKey('TurnOffPrimary') -and -not $urgent['TurnOffPrimary'].Ok) {
                    $urgent[$type] = New-VmsResult 'FAILED' "it was not started, because the frozen Primary could not be powered OFF first and both VMs use the same IP address ($($urgent['TurnOffPrimary'].Message))"
                } else { $urgent[$type] = Invoke-VmsVmOp -Role Secondary -Op Start -Reason $ua.Reason }
            }
            'ReleasePrimary' { $urgent[$type] = Invoke-VmsVmOp -Role Primary -Op Start -Reason $ua.Reason }
        }
    }

    foreach ($a in $d.Actions) {
        switch ($a.Type) {
            'Event' {
                $p = @{ Severity = $a.Severity; Action = $a.Action; Result = 'ALERT'; Message = $a.Message; Alert = [bool]$a.Alert; Title = $a.Title }
                if ($a.Role) { $p.Role = $a.Role }
                if ($a.Detail) { $p.Detail = $a.Detail }
                if (-not $a.Alert) { $p.Result = 'INFO' }
                Write-VmsEvent @p
            }
            'OpenHandoff' {
                if ($keeps) { $st.HandoffId = New-VmsHandoff -Trigger Automatic -Reason $a.Reason -PrimaryDown $a.Down }
                if ($snap.Primary.IsLocal) {
                    $why = Get-VmsOffReason $snap.Primary.Name
                    if ($why) { Write-VmsEvent -Action 'FailoverReason' -Message "Likely cause: $why" -Role Primary }
                }
            }
            'StartSecondary' {
                $res = $urgent['StartSecondary']
                if ($res.Result -eq 'OK') { Write-VmsEvent -Action 'StartSecondary' -Result 'OK' -Message "The watchdog turned ON the Secondary ($($a.Reason))." -Role Secondary }
                elseif ($res.Result -eq 'NOOP') { Write-VmsEvent -Action 'StartSecondary' -Result 'NOOP' -Message "The Secondary was already ON ($($res.Message))." -Role Secondary }
                else { Write-VmsEvent -Severity Critical -Action 'StartSecondary' -Result 'FAILED' -Message "The watchdog could NOT turn ON the Secondary: $($res.Message)" -Role Secondary -Alert -Title 'Secondary did not start' }
            }
            'HoldPrimary' {
                $res = $urgent['HoldPrimary']
                if ($res.Result -eq 'OK') { Write-VmsEvent -Action 'HoldPrimary' -Result 'OK' -Message 'The starting Primary is held PAUSED (nothing is lost) until the Secondary has shut down cleanly, so the two VMs never use the shared IP address together.' -Role Primary }
                elseif ($res.Result -ne 'NOOP') { Write-VmsEvent -Severity Warning -Action 'HoldPrimary' -Result 'FAILED' -Message "Could not hold the Primary paused: $($res.Message). The Secondary is still being shut down cleanly." -Role Primary }
            }
            'ShutdownSecondary' {
                $res = $urgent['ShutdownSecondary']
                if ($res.Result -eq 'OK') { Write-VmsEvent -Action 'StopSecondary' -Result 'OK' -Message "The Secondary is shutting down cleanly ($($a.Reason)); its data is saved." -Role Secondary }
                elseif ($res.Result -ne 'NOOP') { Write-VmsEvent -Severity Critical -Action 'StopSecondary' -Result 'FAILED' -Message "Could not shut down the Secondary: $($res.Message)" -Role Secondary -Alert -Title 'Secondary could not be shut down' }
            }
            'ReleasePrimary' {
                $res = $urgent['ReleasePrimary']
                if ($res.Result -eq 'OK') { Write-VmsEvent -Action 'ReleasePrimary' -Result 'OK' -Message 'The Secondary is OFF: the Primary continues starting.' -Role Primary }
                elseif ($res.Result -ne 'NOOP') { Write-VmsEvent -Severity Critical -Action 'ReleasePrimary' -Result 'FAILED' -Message "The Primary could not be resumed: $($res.Message). Press 1 to turn it ON." -Role Primary -Alert -Title 'Primary still paused' }
            }
            'BeginFailback' { Set-VmsIntent 'failback' '1' (([int]$cfg.ShutdownTimeoutSeconds + 60) * 2) -Replicate }
            'EndFailback' { Clear-VmsIntent 'failback' -Replicate }
            'TurnOffSecondary' {
                $res = $urgent['TurnOffSecondary']
                if ($res.Result -eq 'OK') { Write-VmsEvent -Action 'StopSecondary' -Result 'OK' -Message "The watchdog powered OFF the Secondary at once ($($a.Reason))." -Role Secondary }
                elseif ($res.Result -eq 'NOOP') { Write-VmsEvent -Action 'StopSecondary' -Result 'NOOP' -Message "The Secondary was already OFF ($($res.Message))." -Role Secondary }
                else { Write-VmsEvent -Severity Critical -Action 'StopSecondary' -Result 'FAILED' -Message "The watchdog could NOT power OFF the Secondary: $($res.Message). Both VMs may be ON with the same IP address!" -Role Secondary -Alert -Title 'Secondary could not be turned OFF' }
            }
            'TurnOffPrimary' {
                $res = $urgent['TurnOffPrimary']
                if ($res.Result -eq 'OK') { Write-VmsEvent -Action 'TurnOffPrimary' -Result 'OK' -Message "The watchdog powered OFF the frozen Primary before starting the Secondary ($($a.Reason))." -Role Primary }
                elseif ($res.Result -ne 'NOOP') { Write-VmsEvent -Severity Critical -Action 'TurnOffPrimary' -Result 'FAILED' -Message "The watchdog could NOT power OFF the frozen Primary: $($res.Message). The Secondary was not started (shared IP address)." -Role Primary -Alert -Title 'Frozen Primary could not be turned OFF' }
            }
            'MarkSecondaryUp' {
                if ($keeps) {
                    $hid = $st.HandoffId
                    if (-not $hid) { $open = Get-VmsOpenHandoff; if ($open) { $hid = [long]$open.id; $st.HandoffId = $hid } }
                    if ($hid) {
                        $gap = Set-VmsHandoffSecondaryUp -Id $hid -SecondaryUp $Now
                        $gapText = if ($null -ne $gap) { " The switch took $(Format-VmsDuration $gap)." } else { '' }
                        Write-VmsEvent -Action 'SecondaryServing' -Message "The Secondary is now serving users.$gapText" -Role Secondary -Alert -Title 'Secondary is serving'
                    }
                } else {
                    Write-VmsEvent -Action 'SecondaryServing' -Message 'The Secondary is now serving users.' -Role Secondary -Alert -Title 'Secondary is serving'
                }
            }
            'CloseHandoff' { if ($keeps) { [void](Close-VmsOpenHandoffs $a.By) } }
            'ClearPlanned' {
                Clear-VmsIntent 'planned_stop' -Replicate
                Write-VmsEvent -Action 'PlannedStopEnded' -Message 'The Primary is back ON after the planned stop. Automatic failover covers it again.' -Role Primary
            }
            'AdoptHandoff' {
                Clear-VmsIntent 'adopt_handoff'
                if ($keeps -and -not $st.HandoffId) {
                    # Switchover was started on the other server: record it here, where hand-offs are kept.
                    $st.HandoffId = New-VmsHandoff -Trigger Planned -Reason 'planned switchover started on the other server' -PrimaryDown $Now
                }
            }
        }
    }
    Save-VmsWatchdogRow -State $st -Message ($d.Explain -join ' ') -Started $Started
    return [pscustomobject]@{ State = $st; Snapshot = $snap; Explain = $d.Explain }
}

# ---------------------------------------------------------------------------
# Plain-English overall status (banner text)
# ---------------------------------------------------------------------------

function Get-VmsBanner {
    param($Snapshot, $WatchdogRow)
    $p = $Snapshot.Primary; $s = $Snapshot.Secondary
    $maint = $null -ne (Get-VmsIntent 'maintenance')
    $level = 'Ok'; $text = ''
    if ($p.IsHealthy -and -not $s.IsUp) { $text = 'All good. Primary is serving. Secondary is OFF and ready to take over.' }
    elseif ($p.IsHealthy -and $s.IsUp) { $text = 'BOTH VMs ARE ON and they share one IP address! The Secondary is being shut down cleanly (or press 3).'; $level = 'Bad' }
    elseif ($p.IsHealthy) { $text = 'Primary is serving. Secondary is changing state.'; $level = 'Info' }
    elseif ($s.IsHealthy) {
        $level = 'Warn'
        $h = Get-VmsProp $Snapshot 'OpenHandoff'
        if ($h) {
            $since = ConvertFrom-VmsTs (Get-VmsProp $h 'PrimaryDown')
            $sinceText = if ($since) { $since.ToString('HH:mm') } else { 'earlier' }
            $g = Get-VmsProp $h 'GapSeconds'
            $gap = if ($null -ne $g) { " Secondary took over in $(Format-VmsDuration ([double]$g))." } else { '' }
            $text = "Primary is DOWN since $sinceText. Secondary is serving.$gap"
        } else { $text = 'Primary is not serving. Secondary is serving.' }
    }
    elseif ($p.Booting -or $p.Transitional -or $s.Transitional -or $s.Booting) { $text = 'A VM is changing state. Please wait...'; $level = 'Info' }
    elseif (-not $p.Reachable -and -not $s.Reachable) { $text = 'Cannot see either VM right now.'; $level = 'Bad' }
    else { $text = 'NOBODY IS SERVING. Both VMs are down. Turn ON the Primary (option 1) or the Secondary (option 2).'; $level = 'Bad' }
    foreach ($h in @($p, $s)) {
        if (-not $h.Reachable) {
            $text += " Cannot see the $($h.Role) on $($h.Host): " + $(if ($h.HostPing) { 'its VM Switcher is not answering.' } else { 'the server does not answer.' })
            if ($level -eq 'Ok') { $level = 'Warn' }
        }
    }
    if ($WatchdogRow -and $WatchdogRow.Mode -eq 'FailingBack') {
        $text = 'Switching back to the Primary: the Secondary is shutting down cleanly (no data is lost). The Primary is held paused until it is OFF, so the shared IP address is never used twice.'
        $level = 'Info'
    }
    if ($maint) { $text += ' Auto-failover is PAUSED (maintenance mode).'; if ($level -eq 'Ok') { $level = 'Info' } }
    if (-not $WatchdogRow -or -not $WatchdogRow.Alive) {
        # Lead with the missing protection; never say "All good" while nobody is watching.
        $why = if ($WatchdogRow) { 'the watchdog service on this server is not running' } else { 'the watchdog service has never run on this server' }
        $text = "NO AUTOMATIC FAILOVER FROM THIS SERVER: $why. " + $text.Replace('All good. ', '')
        if ($level -ne 'Bad') { $level = 'Warn' }
    }
    return [pscustomobject]@{ Text = $text; Level = $level; Maintenance = $maint }
}

# ---------------------------------------------------------------------------
# Menu options (shared by terminal and GUI)
# ---------------------------------------------------------------------------

$script:MenuOptions = @(
    [pscustomobject]@{ Key = 1; Id = 'StartPrimary';       Title = 'Turn ON Primary';               Hint = 'Starts the main VM.' }
    [pscustomobject]@{ Key = 2; Id = 'StartSecondary';     Title = 'Turn ON Secondary';             Hint = 'Starts the backup VM.' }
    [pscustomobject]@{ Key = 3; Id = 'StopSecondary';      Title = 'Turn OFF Secondary';            Hint = 'Clean shutdown of backup VM (Primary must be ON).' }
    [pscustomobject]@{ Key = 4; Id = 'PlannedStopPrimary'; Title = 'Planned stop of Primary';       Hint = 'Clean shutdown, no alarm; can switch to Secondary.' }
    [pscustomobject]@{ Key = 5; Id = 'ToggleMaintenance';  Title = 'Pause auto-failover';           Hint = 'Watch only, never act.' }
    [pscustomobject]@{ Key = 6; Id = 'ShowEvents';         Title = 'What happened (event log)';     Hint = 'Plain-English history.' }
    [pscustomobject]@{ Key = 7; Id = 'ShowHandoffs';       Title = 'VM hand-off history';           Hint = 'When one VM stopped, other started.' }
    [pscustomobject]@{ Key = 8; Id = 'TestFailover';       Title = 'Failover test (dry run)';       Hint = 'What would happen? Changes nothing.' }
    [pscustomobject]@{ Key = 9; Id = 'OpenConsole';        Title = 'Open VM console';               Hint = 'See the VM screen.' }
)

function Get-VmsMenuOptions { return $script:MenuOptions }

function New-VmsAvail([bool]$Enabled, [string]$Reason = '', [string]$Title = '', [string]$Hint = '') {
    return [pscustomobject]@{ Enabled = $Enabled; Reason = $Reason; Title = $Title; Hint = $Hint }
}

function Get-VmsOptionAvailability {
    <# For each option: is it allowed right now, and if not, why (one sentence). #>
    param($Snapshot)
    $p = $Snapshot.Primary; $s = $Snapshot.Secondary
    $r = @{}
    foreach ($o in $script:MenuOptions) { $r[$o.Id] = New-VmsAvail $true }
    if (-not $p.Reachable) { $r.StartPrimary = New-VmsAvail $false "Cannot reach the Primary's server $($p.Host)." }
    elseif (-not $p.Exists) { $r.StartPrimary = New-VmsAvail $false "The Primary VM was not found in Hyper-V on $($p.Host)." }
    elseif ($p.IsFrozen) { $r.StartPrimary = New-VmsAvail $true '' 'Restart Primary (frozen)' 'It is ON but not answering. Hard restart.' }
    elseif ($p.IsUp) { $r.StartPrimary = New-VmsAvail $false 'The Primary is already ON.' }
    elseif ($p.Transitional) { $r.StartPrimary = New-VmsAvail $false 'The Primary is busy changing state. Wait a moment.' }
    if (-not $s.Reachable) { $r.StartSecondary = New-VmsAvail $false "Cannot reach the Secondary's server $($s.Host)." }
    elseif (-not $s.Exists) { $r.StartSecondary = New-VmsAvail $false "The Secondary VM was not found in Hyper-V on $($s.Host)." }
    elseif ($s.IsFrozen) { $r.StartSecondary = New-VmsAvail $true '' 'Restart Secondary (frozen)' 'It is ON but not answering. Hard restart.' }
    elseif ($s.IsUp) { $r.StartSecondary = New-VmsAvail $false 'The Secondary is already ON.' }
    elseif ($p.Reachable -and ($p.IsUp -or $p.State -like 'Running*')) { $r.StartSecondary = New-VmsAvail $false 'Only while the Primary is OFF (both VMs use the same IP address). Use option 4 to switch on purpose.' }
    elseif ($s.Transitional) { $r.StartSecondary = New-VmsAvail $false 'The Secondary is busy changing state. Wait a moment.' }
    if (-not $s.Reachable) { $r.StopSecondary = New-VmsAvail $false "Cannot reach the Secondary's server $($s.Host)." }
    elseif (-not $p.IsHealthy) { $r.StopSecondary = New-VmsAvail $false "Allowed only when the Primary is ON and healthy. The Primary is $(Get-VmsHealthWord $p)." }
    elseif (-not ($s.IsUp -or $s.State -like 'Running*')) { $r.StopSecondary = New-VmsAvail $false 'The Secondary is not ON, so there is nothing to turn off.' }
    if (-not $p.Reachable) { $r.PlannedStopPrimary = New-VmsAvail $false "Cannot reach the Primary's server $($p.Host)." }
    elseif (-not $p.IsUp) { $r.PlannedStopPrimary = New-VmsAvail $false 'The Primary is not ON.' }
    return $r
}

function Wait-VmsHealthy {
    param([string]$Role, [int]$TimeoutSeconds, [scriptblock]$OnWait)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $h = Get-VmsHealth $Role
        if ($h.IsHealthy) { return $h }
        if ($OnWait) { & $OnWait $h ([int]$sw.Elapsed.TotalSeconds) }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Invoke-VmsAction {
    <#
      Runs one menu option from either server. VM work is routed to the server that holds the VM.
      Every outcome (OK / REFUSED / FAILED / NOOP) is written to the event log with the Windows user and program.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('StartPrimary', 'StartSecondary', 'StopSecondary', 'PlannedStopPrimary', 'ToggleMaintenance', 'SetMaintenance', 'TestFailover', 'OpenConsole')][string]$Id,
        [switch]$SwitchoverFirst,
        [Nullable[bool]]$On = $null,
        [ValidateSet('Primary', 'Secondary')][string]$Role = 'Primary',
        [scriptblock]$Progress
    )
    $cfg = Get-VmsConfig
    switch ($Id) {
        { $_ -in 'StartPrimary', 'StartSecondary' } {
            $vr = if ($Id -eq 'StartPrimary') { 'Primary' } else { 'Secondary' }
            $other = if ($vr -eq 'Primary') { 'Secondary' } else { 'Primary' }
            $h = Get-VmsHealth $vr
            $oh = Get-VmsHealth $other
            $otherOn = [bool]($oh.Reachable -and $oh.Exists -and ($oh.IsUp -or $oh.State -like 'Running*'))
            $note = ''
            if (-not $h.Reachable) { $r = New-VmsResult 'REFUSED' "Cannot reach the $vr's server $($h.Host), so it cannot be turned ON from here." }
            elseif (-not $h.Exists) { $r = New-VmsResult 'REFUSED' "The $vr VM '$($h.Name)' was not found in Hyper-V on $($h.Host)." }
            elseif ($h.IsUp -and -not $h.IsFrozen) { $r = New-VmsResult 'NOOP' "The $vr is already ON. Nothing to do." }
            elseif ($vr -eq 'Secondary' -and $otherOn) {
                # Both VMs share one IP address: the Secondary may only run while the Primary is OFF.
                $r = New-VmsResult 'REFUSED' 'Not allowed: the Primary is ON and both VMs use the same IP address. Turn ON the Secondary only while the Primary is OFF. To move users on purpose, use option 4 (planned stop of Primary).'
            }
            else {
                $r = $null
                if ($vr -eq 'Primary' -and $otherOn) {
                    # Shared IP address: shut the Secondary down CLEANLY first (no data lost), then start the Primary.
                    if ($Progress) { & $Progress 'Shutting down the Secondary cleanly first (shared IP address)...' }
                    $off = Invoke-VmsVmOp -Role Secondary -Op Stop -Reason 'option 1: the Primary is being turned ON'
                    if (-not $off.Ok) { $r = New-VmsResult 'FAILED' "The Primary was NOT started, because the Secondary could not be shut down first (both use the same IP address): $($off.Message)" }
                    else {
                        $limit = [int]$cfg.ShutdownTimeoutSeconds + 20
                        $sw = [Diagnostics.Stopwatch]::StartNew(); $isOff = $false
                        while ($sw.Elapsed.TotalSeconds -lt $limit) {
                            $sh = Get-VmsHealth Secondary
                            if ($sh.Reachable -and $sh.State -eq 'Off') { $isOff = $true; break }
                            if ($Progress) { & $Progress "Waiting for the Secondary to finish shutting down cleanly ($([int]$sw.Elapsed.TotalSeconds) s)..." }
                            Start-Sleep -Milliseconds 500
                        }
                        if (-not $isOff) { $r = New-VmsResult 'FAILED' "The Primary was NOT started: the Secondary did not turn OFF within $limit s (shared IP address). Check it in Hyper-V Manager." }
                        else {
                            if (Test-VmsKeepsHandoffs) { [void](Close-VmsOpenHandoffs "$(Get-VmsActor) via $script:Source (option 1)") }
                            $note = " The Secondary was shut down cleanly first ($([int]$sw.Elapsed.TotalSeconds) s), because both VMs use the same IP address."
                        }
                    }
                }
                if (-not $r) {
                    $frozen = $h.IsFrozen
                    $how = if ($frozen) { 'restart' } elseif ($h.Light -eq 'Yellow') { 'resume' } else { 'boot' }
                    if ($vr -eq 'Primary' -and -not $frozen) { Clear-VmsIntent 'planned_stop' -Replicate }
                    $op = Invoke-VmsVmOp -Role $vr -Op $(if ($frozen) { 'Restart' } else { 'Start' })
                    if ($op.Result -eq 'OK') {
                        $msg = switch ($how) {
                            'restart' { "The frozen $vr was restarted. It is ready when its light turns steady green (usually 1-2 minutes)." }
                            'resume' { "The $vr is turning ON, resuming from a saved state (a few seconds)." }
                            default { "The $vr is turning ON. It is ready when its light turns steady green (usually 1-2 minutes)." }
                        }
                        $r = New-VmsResult 'OK' ($msg + $note)
                    } else { $r = New-VmsResult $op.Result $op.Message }
                }
            }
            Write-VmsEvent -Severity $(if ($r.Ok) { 'Info' } else { 'Warning' }) -Action $Id -Result $r.Result -Message $r.Message -Role $vr
            return $r
        }
        'StopSecondary' {
            $snap = Get-VmsSnapshot
            $p = $snap.Primary; $s = $snap.Secondary
            $sOn = [bool]($s.Reachable -and $s.Exists -and ($s.IsUp -or $s.State -like 'Running*'))
            if (-not $s.Reachable) { $r = New-VmsResult 'REFUSED' "Cannot reach the Secondary's server $($s.Host)." }
            elseif (-not $p.IsHealthy) { $r = New-VmsResult 'REFUSED' "Not allowed: the Primary is $(Get-VmsHealthWord $p). Turning OFF the Secondary now would leave nobody serving. Turn ON the Primary first (option 1)." }
            elseif (-not $sOn) { $r = New-VmsResult 'NOOP' "The Secondary is already $(Get-VmsHealthWord $s). Nothing to turn off." }
            else {
                # Clean shutdown (data is saved). Hyper-V powers it off only if Windows inside hangs for ShutdownTimeoutSeconds.
                $op = Invoke-VmsVmOp -Role Secondary -Op Stop -Reason 'option 3'
                if ($op.Ok) {
                    if (Test-VmsKeepsHandoffs) { [void](Close-VmsOpenHandoffs "$(Get-VmsActor) via $script:Source (option 3)") }
                    $r = New-VmsResult 'OK' 'The Secondary is shutting down cleanly (its data is saved) and will be OFF in a moment. The Primary is serving.'
                } else { $r = New-VmsResult $op.Result $op.Message }
            }
            Write-VmsEvent -Severity $(if ($r.Result -in 'OK', 'NOOP') { 'Info' } else { 'Warning' }) -Action 'StopSecondary' -Result $r.Result -Message $r.Message -Role Secondary
            return $r
        }
        'PlannedStopPrimary' {
            $p = Get-VmsHealth Primary
            if (-not $p.Reachable) {
                $r = New-VmsResult 'REFUSED' "Cannot reach the Primary's server $($p.Host)."
                Write-VmsEvent -Severity Warning -Action 'PlannedStopPrimary' -Result $r.Result -Message $r.Message -Role Primary
                return $r
            }
            if (-not $p.IsUp) {
                $r = New-VmsResult 'NOOP' "The Primary is already $(Get-VmsHealthWord $p)."
                Write-VmsEvent -Action 'PlannedStopPrimary' -Result $r.Result -Message $r.Message -Role Primary
                return $r
            }
            Set-VmsIntent 'planned_stop' '1' ([int]$cfg.PlannedStopMinutes * 60) -Replicate
            if ($Progress) { & $Progress 'Shutting down the Primary cleanly...' }
            $op = Invoke-VmsVmOp -Role Primary -Op Stop -Reason 'planned stop'
            if (-not $op.Ok) {
                Clear-VmsIntent 'planned_stop' -Replicate
                $r = New-VmsResult 'FAILED' "Could not shut down the Primary: $($op.Message)"
                Write-VmsEvent -Severity Warning -Action 'PlannedStopPrimary' -Result $r.Result -Message $r.Message -Role Primary
                return $r
            }
            if (-not $SwitchoverFirst) {
                $r = New-VmsResult 'OK' 'The Primary is shutting down on purpose. No failover was started. Remember: nobody is serving until a VM is turned ON.'
                Write-VmsEvent -Action 'PlannedStopPrimary' -Result $r.Result -Message $r.Message -Role Primary
                return $r
            }
            # Switchover: both VMs share one IP address, so the Primary must be fully OFF before the Secondary starts.
            $limit = [int]$cfg.ShutdownTimeoutSeconds + 20
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $down = $null
            while ($sw.Elapsed.TotalSeconds -lt $limit) {
                $ph = Get-VmsHealth Primary
                if ($ph.Reachable -and $ph.State -eq 'Off') { $down = Get-Date; break }
                if ($Progress) { & $Progress "Waiting for the Primary to finish shutting down ($([int]$sw.Elapsed.TotalSeconds) s)..." }
                Start-Sleep -Seconds 1
            }
            if (-not $down) {
                $r = New-VmsResult 'FAILED' "Switchover stopped: the Primary did not turn OFF within $limit s, so the Secondary was NOT started (shared IP address). Check the Primary in Hyper-V Manager."
                Write-VmsEvent -Severity Warning -Action 'PlannedStopPrimary' -Result $r.Result -Message $r.Message -Role Primary -Alert -Title 'Switchover problem'
                return $r
            }
            if ($Progress) { & $Progress 'Primary is OFF. Turning ON the Secondary...' }
            if (Test-VmsKeepsHandoffs) {
                $hid = New-VmsHandoff -Trigger Planned -Reason "planned switchover by $(Get-VmsActor)" -PrimaryDown $down
                Set-VmsIntent 'adopt_handoff' ([string]$hid) 600 -Replicate
            } else {
                Set-VmsIntent 'adopt_handoff' '0' 600 -Replicate
            }
            $startRes = Invoke-VmsVmOp -Role Secondary -Op Start -Reason 'planned switchover'
            if ($startRes.Ok) {
                $r = New-VmsResult 'OK' 'Planned switchover done: the Primary is OFF and the Secondary is turning ON (it serves once Windows inside it is up). No failover alarm was raised.'
            } else {
                $r = New-VmsResult 'FAILED' "The Primary is OFF but the Secondary did not start: $($startRes.Message). NOBODY is serving - use option 1 or 2."
            }
            Write-VmsEvent -Severity $(if ($r.Ok) { 'Info' } else { 'Critical' }) -Action 'PlannedStopPrimary' -Result $r.Result -Message $r.Message -Role Primary -Alert:(-not $r.Ok) -Title 'Switchover problem'
            return $r
        }
        { $_ -in 'ToggleMaintenance', 'SetMaintenance' } {
            $current = $null -ne (Get-VmsIntent 'maintenance')
            $target = if ($null -ne $On) { [bool]$On } else { -not $current }
            if ($target -eq $current) {
                $r = New-VmsResult 'NOOP' $(if ($current) { 'Auto-failover is already paused.' } else { 'Auto-failover is already active.' })
            } elseif ($target) {
                Set-VmsIntent 'maintenance' '1' -Replicate
                $r = New-VmsResult 'OK' 'Auto-failover is PAUSED (maintenance mode) on both servers. The watchdogs keep watching but will not start or stop anything. Remember to resume it (option 5).'
            } else {
                Clear-VmsIntent 'maintenance' -Replicate
                $r = New-VmsResult 'OK' 'Auto-failover is ACTIVE again on both servers. The Secondary is turned ON if the Primary fails.'
            }
            Write-VmsEvent -Severity $(if ($target) { 'Warning' } else { 'Info' }) -Action 'Maintenance' -Result $r.Result -Message $r.Message -Alert:($r.Result -eq 'OK') -Title 'Maintenance mode'
            return $r
        }
        'TestFailover' {
            $lines = Get-VmsDryRun
            $r = New-VmsResult 'INFO' ($lines -join [Environment]::NewLine)
            Write-VmsEvent -Action 'TestFailover' -Result 'INFO' -Message 'Ran a failover test (dry run). Nothing was changed.' -Detail ($lines -join ' | ')
            return $r
        }
        'OpenConsole' {
            $vc = Get-VmsVmConfig $Role
            $target = if (Test-VmsRoleIsLocal $Role) { 'localhost' } else { [string]$vc.Host }
            if ($cfg.Provider -eq 'Simulated') {
                $r = New-VmsResult 'INFO' "Demo mode: on the real servers this opens the screen of $($vc.Name) on $target."
            } else {
                $exe = Join-Path $env:windir 'System32\vmconnect.exe'
                if (-not (Test-Path -LiteralPath $exe)) { $r = New-VmsResult 'FAILED' 'vmconnect.exe (Hyper-V tools) is not installed on this machine.' }
                else {
                    Start-Process -FilePath $exe -ArgumentList @($target, "`"$($vc.Name)`"") | Out-Null
                    $extra = if ($target -ne 'localhost') { ' Windows may ask for an administrator login of that server.' } else { '' }
                    $r = New-VmsResult 'OK' "Opened the console of the $Role ($($vc.Name) on $target).$extra"
                }
            }
            Write-VmsEvent -Action 'OpenConsole' -Result $r.Result -Message $r.Message -Role $Role
            return $r
        }
    }
}

function Get-VmsDryRun {
    <# Explains, in plain English, what the watchdog would do now and if the Primary failed now. #>
    $cfg = Get-VmsConfig
    $snap = Get-VmsSnapshot
    $row = Get-VmsWatchdogRow
    $state = if ($row) { $row.State } else { New-VmsWatchdogState }
    $maint = $null -ne (Get-VmsIntent 'maintenance')
    $planned = $null -ne (Get-VmsIntent 'planned_stop')
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("This server : $env:COMPUTERNAME, holds the $((Get-VmsLocalRole).ToUpper())")
    [void]$lines.Add("Primary     : $(Get-VmsHealthWord $snap.Primary) on $(Get-VmsServerLabel Primary) - $($snap.Primary.Summary)")
    [void]$lines.Add("Secondary   : $(Get-VmsHealthWord $snap.Secondary) on $(Get-VmsServerLabel Secondary) - $($snap.Secondary.Summary)")
    if (-not $row -or -not $row.Alive) { [void]$lines.Add('WARNING     : the watchdog service on this server is NOT running.') }
    if ($maint) { [void]$lines.Add('NOTE        : maintenance mode is ON, so the watchdog would not act.') }
    $d = Get-VmsWatchdogDecision -Primary $snap.Primary -Secondary $snap.Secondary -State $state -Now (Get-Date) -Config $cfg -Maintenance $maint -PlannedStop $planned
    foreach ($e in $d.Explain) { [void]$lines.Add("Right now   : $e") }
    if ($state.Mode -eq 'Normal' -and $snap.Primary.Reachable) {
        $fake = $snap.Primary.PSObject.Copy()
        $fake.State = 'Off'; $fake.IsHealthy = $false; $fake.IsUp = $false; $fake.Light = 'Dark'; $fake.PingOk = $false
        $h = Get-VmsWatchdogDecision -Primary $fake -Secondary $snap.Secondary -State (New-VmsWatchdogState) -Now (Get-Date) -Config $cfg -Maintenance $maint -PlannedStop $false
        $what = ($h.Explain | Where-Object { $_ -like 'Primary failed*' -or $_ -like 'Primary is down*' } | Select-Object -First 1)
        $resume = if (-not $snap.Secondary.Reachable) { "BUT the Secondary's server cannot be reached right now, so this would fail." }
        elseif ($snap.Secondary.Light -eq 'Yellow') { 'The Secondary is hibernated, so it resumes in seconds.' }
        elseif ($snap.Secondary.IsUp) { 'The Secondary is already ON.' }
        else { 'The Secondary is OFF, so it boots fully: it serves once Windows inside it is up (typically 1-2 minutes).' }
        [void]$lines.Add("If the Primary crashed now : $what $resume")
        $n = [int]$cfg.MissedPingsForFailover; $sec = $n * [int]$cfg.CheckIntervalSeconds
        [void]$lines.Add("If the Primary froze now   : after $n missed heartbeat checks (about $sec s) the same failover happens.")
        [void]$lines.Add("If server $($cfg.Primary.Host) died now : after $n checks with no ping and no VM Switcher (about $sec s) the Secondary's server turns the Secondary ON.")
        [void]$lines.Add("When the Primary comes back : within about $([int]$cfg.FastCheckIntervalSeconds + 2) s it is held PAUSED (nothing lost), the Secondary shuts down cleanly (data saved), then the Primary continues. The shared IP address is never used twice.")
    }
    return , $lines.ToArray()
}

# ---------------------------------------------------------------------------
# History readers for terminal/GUI (local + merged with the other server)
# ---------------------------------------------------------------------------

function Get-VmsEvents([int]$Limit = 200, [switch]$UserActionsOnly) {
    $where = if ($UserActionsOnly) { "WHERE source IN ('GUI','Terminal')" } else { '' }
    return , (Get-VmsDb).Query("SELECT ts AS [Time], severity AS [Level], source AS [By program], actor AS [User], message AS [What happened] FROM events $where ORDER BY id DESC LIMIT ?", @($Limit))
}

function Get-VmsHandoffs([int]$Limit = 100) {
    return , (Get-VmsDb).Query(@'
SELECT id AS [#], trigger AS [Type], primary_down_ts AS [Primary stopped], secondary_up_ts AS [Secondary serving],
       CASE WHEN gap_seconds IS NULL THEN '' ELSE CAST(gap_seconds AS TEXT) || ' s' END AS [Gap],
       IFNULL(failback_ts,'(still on Secondary)') AS [Back to Primary], IFNULL(failback_by,'') AS [Ended by], reason AS [Why]
FROM handoffs ORDER BY id DESC LIMIT ?
'@, @($Limit))
}

function Get-VmsTransitions([int]$Limit = 200) {
    return , (Get-VmsDb).Query('SELECT ts AS [Time], vm_role AS [VM], message AS [Change] FROM vm_transitions ORDER BY id DESC LIMIT ?', @($Limit))
}

function Get-VmsMergedEvents {
    <# This server's events plus the other server's, newest first, with a "Server" column. #>
    param([int]$Limit = 150, [switch]$UserActionsOnly, [switch]$LocalOnly)
    $local = Get-VmsEvents $Limit -UserActionsOnly:$UserActionsOnly
    $t = $local.Clone()
    [void]$t.Columns.Add('Server', [object])
    $t.Columns['Server'].SetOrdinal(1)
    $me = "$env:COMPUTERNAME (this)"
    foreach ($r in $local.Rows) { $n = $t.NewRow(); foreach ($c in $local.Columns) { $n[$c.ColumnName] = $r[$c.ColumnName] }; $n['Server'] = $me; $t.Rows.Add($n) }
    if (-not $LocalOnly -and (Get-VmsRemoteRole)) {
        try {
            $resp = Invoke-VmsPeer -Method GET -Path "/vms/events?limit=$Limit"
            $peerName = "$(Get-VmsPeerAddress) (other)"
            foreach ($w in @(Get-VmsProp $resp 'Rows' @())) {
                if ($UserActionsOnly -and (Get-VmsProp $w 'By program') -notin 'GUI', 'Terminal') { continue }
                $n = $t.NewRow()
                foreach ($c in $local.Columns) { $v = Get-VmsProp $w $c.ColumnName; if ($null -eq $v) { $v = [DBNull]::Value }; $n[$c.ColumnName] = $v }
                $n['Server'] = $peerName
                $t.Rows.Add($n)
            }
        } catch { }
    }
    $v = $t.DefaultView
    $v.Sort = 'Time DESC'
    $sorted = $v.ToTable()
    while ($sorted.Rows.Count -gt $Limit) { $sorted.Rows.RemoveAt($sorted.Rows.Count - 1) }
    return , $sorted
}

function Get-VmsHandoffsAnywhere([int]$Limit = 100) {
    <# Hand-offs are kept by the Secondary's server; fetch them from there if that is the other server. #>
    if (Test-VmsKeepsHandoffs) { return , (Get-VmsHandoffs $Limit) }
    $t = New-Object System.Data.DataTable
    foreach ($c in '#', 'Type', 'Primary stopped', 'Secondary serving', 'Gap', 'Back to Primary', 'Ended by', 'Why') { [void]$t.Columns.Add($c, [object]) }
    try {
        $resp = Invoke-VmsPeer -Method GET -Path '/vms/handoffs'
        foreach ($w in @(Get-VmsProp $resp 'Rows' @())) {
            $n = $t.NewRow()
            foreach ($c in $t.Columns) { $v = Get-VmsProp $w $c.ColumnName; if ($null -eq $v) { $v = [DBNull]::Value }; $n[$c.ColumnName] = $v }
            $t.Rows.Add($n)
        }
    } catch { }
    return , $t
}

Export-ModuleMember -Function *-Vms*, Get-VmsHome, Format-VmsTs, ConvertFrom-VmsTs, Format-VmsDuration, ConvertTo-VmsHealth, Get-VmsLightWord, Get-VmsHealthWord, Get-VmsProp

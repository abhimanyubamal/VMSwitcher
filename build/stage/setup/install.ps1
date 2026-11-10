#requires -Version 5.1
<#
  Called by VMSwitcher-Setup.exe (as administrator) after the files are copied. Run it on BOTH servers.
  1. Data folder (locked down)  2. config.json (+ shared key, DPAPI-encrypted)  3. Event Log source
  4. Firewall: TCP 47160 + ping, only from the other server  5. Watchdog service  6. Tray app at logon
  7. Self-test report
#>
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [string]$PrimaryName = '',      # no defaults: the installer passes what the person typed
    [string]$PrimaryHost = '',
    [string]$SecondaryName = '',
    [string]$SecondaryHost = '',
    [string]$SharedKeyFile = '',
    [int]$Port = 47160,
    [ValidateSet('Auto', 'Primary', 'Secondary', 'Both')][string]$Role = 'Auto',   # chosen on the installer's first page
    [switch]$Demo
)
$ErrorActionPreference = 'Stop'
$ServiceName = 'VMSwitcherWatchdog'
$TaskName = 'VM Switcher Tray'
$Data = Join-Path $env:ProgramData 'VMSwitcher'
$Report = New-Object System.Collections.ArrayList
function Note([string]$Status, [string]$Text) { [void]$Report.Add(('{0,-6} {1}' -f $Status, $Text)) }

if (-not ($PrimaryName -and $PrimaryHost -and $SecondaryName -and $SecondaryHost)) {
    New-Item -ItemType Directory -Force -Path $Data | Out-Null
    [IO.File]::WriteAllText((Join-Path $Data 'selftest.txt'), "VM Switcher - installation self-test`r`n`r`nFAIL   The Primary and Secondary VM names and server IP addresses were not given. Run the installer again and fill them in.`r`n", (New-Object Text.UTF8Encoding($false)))
    exit 1
}

# 1. Data folder: only SYSTEM and Administrators (logs show who did what).
New-Item -ItemType Directory -Force -Path $Data, (Join-Path $Data 'logs') | Out-Null
& icacls.exe $Data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /Q | Out-Null
Note 'OK' "Data folder ready: $Data (SYSTEM + Administrators only)"

# 2. config.json: keep tuned settings from an earlier install, update servers, VMs, mode and key.
$cfgPath = Join-Path $Data 'config.json'
$default = Get-Content (Join-Path $InstallDir 'app\config.default.json') -Raw | ConvertFrom-Json
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($p in $default.PSObject.Properties) { if (-not ($cfg.PSObject.Properties.Name -contains $p.Name)) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value } }
    Note 'OK' 'Existing config.json kept and updated'
} else { $cfg = $default }
$cfg.Primary = [pscustomobject]@{ Name = $PrimaryName; Host = $PrimaryHost }
$cfg.Secondary = [pscustomobject]@{ Name = $SecondaryName; Host = $SecondaryHost }
$cfg.Provider = if ($Demo) { 'Simulated' } else { 'HyperV' }
$cfg.LocalRole = $Role          # the answer to "Which server is this?" (Auto = detect)
$cfg.ListenPort = $Port; $cfg.PeerPort = $Port
if ($SharedKeyFile -and (Test-Path $SharedKeyFile)) {
    $plain = (Get-Content $SharedKeyFile -Raw).Trim()
    Remove-Item $SharedKeyFile -Force -ErrorAction SilentlyContinue
    if ($plain) {
        Add-Type -AssemblyName System.Security
        $cfg.SharedKeyProtected = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine'))
        $cfg.SharedKey = ''
        Note 'OK' 'Shared key saved (encrypted for this server with Windows DPAPI)'
    }
}
if (-not $cfg.SharedKeyProtected -and -not $cfg.SharedKey) { Note 'FAIL' 'No shared key is set. Run the installer again and type the same key on both servers.' }
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Note 'OK' ("Mode: " + $(if ($Demo) { 'DEMO (simulated VMs, nothing real is touched)' } else { 'REAL Hyper-V' }))
Note 'OK' "Primary   = $PrimaryName on server $PrimaryHost"
Note 'OK' "Secondary = $SecondaryName on server $SecondaryHost"

# Which VM lives here? (decides the other server's address for the firewall)
$env:VMSWITCHER_HOME = $Data
Import-Module (Join-Path $InstallDir 'app\VMSwitcher.Core.psm1') -Force -DisableNameChecking
Initialize-Vms -Source 'Installer'
$role = Get-VmsLocalRole -Refresh
$peer = Get-VmsPeerAddress
$myIps = Get-VmsLocalAddresses
Close-Vms
if (-not $Demo -and $Role -in 'Primary', 'Secondary') {
    $expected = if ($Role -eq 'Primary') { $PrimaryHost } else { $SecondaryHost }
    if ($myIps -contains $expected) { Note 'OK' "You chose the $($Role.ToUpper()) server; this machine does have the IP $expected." }
    else { Note 'WARN' "You chose the $($Role.ToUpper()) server ($expected), but this machine's IP addresses are: $($myIps -join ', '). If that is wrong, run the installer again and pick the other server." }
}
switch ($role) {
    'Primary' { Note 'OK' "This server holds the PRIMARY. The other server is $peer." }
    'Secondary' { Note 'OK' "This server holds the SECONDARY. The other server is $peer." }
    'Both' { Note 'OK' 'This server holds BOTH VMs (single-server layout, no other server needed).' }
    default { Note 'FAIL' "This server holds neither VM and its IP matches neither $PrimaryHost nor $SecondaryHost. Check the names and IPs." }
}

# 3. Windows Event Log source.
try {
    if (-not [Diagnostics.EventLog]::SourceExists('VMSwitcher')) { New-EventLog -LogName Application -Source 'VMSwitcher' }
    Write-EventLog -LogName Application -Source 'VMSwitcher' -EventId 1000 -EntryType Information -Message "VM Switcher installed in $InstallDir (this server holds: $role)."
    Note 'OK' 'Windows Event Log source "VMSwitcher" registered (Application log)'
} catch { Note 'WARN' "Could not register the Event Log source: $($_.Exception.Message)" }

# 4. Firewall: only the other server may talk to VM Switcher, and ping this server.
try {
    Get-NetFirewallRule -Group 'VM Switcher' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $from = if ($peer) { @($peer) } else { @($PrimaryHost, $SecondaryHost) }
    if ($role -ne 'Both') {
        New-NetFirewallRule -DisplayName "VM Switcher - other server (TCP $Port)" -Group 'VM Switcher' -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $from -Action Allow -Profile Any | Out-Null
        New-NetFirewallRule -DisplayName 'VM Switcher - ping from other server' -Group 'VM Switcher' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress $from -Action Allow -Profile Any | Out-Null
        Note 'OK' "Firewall: TCP $Port and ping allowed from $($from -join ', ') only"
    }
} catch { Note 'WARN' "Could not add the firewall rules: $($_.Exception.Message). Open TCP $Port and ICMP echo from the other server by hand." }

# 5. Watchdog service (auto start, restart on failure).
$svcExe = Join-Path $InstallDir 'VMSwitcherService.exe'
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    & sc.exe config $ServiceName binPath= "`"$svcExe`"" start= auto | Out-Null
} else {
    & sc.exe create $ServiceName binPath= "`"$svcExe`"" start= auto DisplayName= 'VM Switcher Watchdog' | Out-Null
}
& sc.exe description $ServiceName 'Watches the Primary and Secondary VMs (on this server and the other server) every 3 seconds and turns ON the Secondary if the Primary fails.' | Out-Null
# Real servers: start only after Hyper-V's own management service (vmms), so the first checks see real VM states.
if (-not $Demo -and (Get-Service -Name vmms -ErrorAction SilentlyContinue)) { & sc.exe config $ServiceName depend= vmms | Out-Null }
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
& sc.exe failureflag $ServiceName 1 | Out-Null
try {
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 8
    $svc = Get-Service -Name $ServiceName
    Note $(if ($svc.Status -eq 'Running') { 'OK' } else { 'FAIL' }) "Watchdog service: $($svc.Status) (starts automatically with Windows)"
} catch { Note 'FAIL' "Watchdog service did not start: $($_.Exception.Message)" }

# 6. Tray app at logon for administrators (highest privileges, so no UAC prompt every logon).
try {
    $adminGroup = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value
    $action = New-ScheduledTaskAction -Execute (Join-Path $InstallDir 'VMSwitcher.exe') -Argument '-Tray'
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId $adminGroup -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Note 'OK' 'Tray app starts at logon for administrators (pop-ups and alert sound; it never jumps in front of your work)'
} catch { Note 'WARN' "Could not register the tray app at logon: $($_.Exception.Message)" }

# 7. Self-test.
if (-not $Demo -and $role -in 'Primary', 'Secondary', 'Both') {
    if (Get-Module -ListAvailable -Name Hyper-V) {
        Import-Module Hyper-V -ErrorAction SilentlyContinue
        $mine = if ($role -eq 'Both') { @('Primary', 'Secondary') } else { @($role) }
        foreach ($r in $mine) {
            $name = if ($r -eq 'Primary') { $PrimaryName } else { $SecondaryName }
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if (-not $vm) { Note 'FAIL' "$r VM '$name' NOT found in Hyper-V on this server."; continue }
            Note 'OK' "$r VM '$name' found (state: $($vm.State))"
            $hb = Get-VMIntegrationService -VM $vm -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Heartbeat*' } | Select-Object -First 1
            if ($hb -and $hb.Enabled) { Note 'OK' "$r heartbeat service enabled (status: $($hb.PrimaryStatusDescription))" }
            else { Note 'FAIL' "$r heartbeat service is DISABLED or missing. Enable it: Hyper-V Manager > $name > Settings > Integration Services > Heartbeat. Without it, VM Switcher thinks the VM is frozen." }
            if ($r -eq 'Primary' -and [string]$vm.AutomaticStartAction -ne 'Nothing') {
                # Both VMs share one IP address. After a reboot of this server, VM Switcher must be running BEFORE
                # Hyper-V auto-starts the Primary, so it can power the Secondary off in time.
                if ([int]$vm.AutomaticStartDelay -lt 60) {
                    Note 'WARN' "The Primary auto-starts only $([int]$vm.AutomaticStartDelay) s after this server boots. Recommended: 60 s, so VM Switcher can power OFF the Secondary before the Primary uses the shared IP address. Run: Set-VM -Name '$name' -AutomaticStartDelay 60"
                } else { Note 'OK' "The Primary auto-starts $([int]$vm.AutomaticStartDelay) s after boot (VM Switcher is ready before it)" }
            }
        }
    } else { Note 'FAIL' 'Hyper-V PowerShell module is missing. Install it: Install-WindowsFeature Hyper-V-PowerShell' }
}
if ($role -in 'Primary', 'Secondary') {
    $env:VMSWITCHER_HOME = $Data
    Import-Module (Join-Path $InstallDir 'app\VMSwitcher.Core.psm1') -Force -DisableNameChecking
    Initialize-Vms -Source 'Installer'
    if (Test-VmsHostPing $peer) { Note 'OK' "Other server $peer answers ping" } else { Note 'WARN' "Other server $peer does not answer ping. Fine if it is still being set up; otherwise allow ICMP echo between the servers." }
    try {
        $st = Invoke-VmsPeer -Method GET -Path '/vms/status' -TimeoutMs 3000
        Note 'OK' "VM Switcher on $peer answers and the shared keys match (it holds the $((Get-VmsProp $st 'LocalRole' '?').ToUpper()))"
    } catch {
        if ($_.Exception.Message -like '*do not match*') { Note 'FAIL' "VM Switcher on $peer REJECTED us: the shared keys are different. Re-run the installer with the same key on both servers." }
        else { Note 'WARN' "VM Switcher on $peer is not answering yet ($($_.Exception.Message)). Normal if you have not installed it there yet. Install it there with the SAME shared key." }
    }
    $row = $null
    for ($i = 0; $i -lt 10 -and -not ($row -and $row.Alive); $i++) { Start-Sleep -Seconds 1; $row = Get-VmsWatchdogRow }
    if ($row -and $row.Alive) { Note 'OK' "Watchdog is checking the VMs (mode: $($row.Mode))" } else { Note 'WARN' 'Watchdog has not reported yet. Open VM Switcher in a minute and look at the "Watchdog" pill.' }
    Close-Vms
}

$fails = @($Report | Where-Object { $_ -like 'FAIL*' }).Count
$head = @(
    'VM Switcher - installation self-test'
    "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Server: $env:COMPUTERNAME   Installed in: $InstallDir"
    ''
    $(if ($fails -eq 0) { 'RESULT: everything needed on this server is in place.' } else { "RESULT: $fails problem(s) need attention (lines marked FAIL)." })
    'Remember: install VM Switcher on BOTH servers with the SAME shared key.'
    ''
)
$text = ($head + $Report + @('', "Logs: $Data\logs", "Settings: $cfgPath (restart the 'VM Switcher Watchdog' service after editing)")) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $Data 'selftest.txt'), $text, (New-Object Text.UTF8Encoding($false)))
exit 0

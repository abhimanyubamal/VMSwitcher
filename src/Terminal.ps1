#requires -Version 5.1
<#
  VM Switcher terminal.
    Interactive:   VMSwitcherTerminal.exe            (or powershell -File Terminal.ps1)
    One option:    VMSwitcherTerminal.exe 3          (runs option 3 and exits; exit code 0 = OK)
    Print screen:  Terminal.ps1 -Snapshot            (draws the status screen once, for logs/docs)
#>
param(
    [ValidateRange(1, 9)][int]$Option = 0,
    [switch]$Yes,                 # skip confirmations in -Option mode
    [switch]$Switchover,          # with -Option 4: start the Secondary first
    [ValidateSet('Primary', 'Secondary')][string]$Vm = 'Primary',   # with -Option 9
    [switch]$Snapshot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VMSwitcher.Core.psm1') -Force -DisableNameChecking
Initialize-Vms -Source 'Terminal'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$Host.UI.RawUI.WindowTitle = 'VM Switcher - Terminal'

$Dot = [string][char]0x2588 + [char]0x2588      # solid lamp, easy to see from a distance
$Ring = [string][char]0x2591 + [char]0x2591     # unlit lamp
$Width = 78
$ConsoleColorFor = @{ Green = 'Green'; Yellow = 'Yellow'; Grey = 'Gray'; Dark = 'DarkGray' }

function Seg([string]$Text, [string]$Color = 'White') { return , @($Text, $Color) }

function Set-CursorVisible([bool]$On) { try { [Console]::CursorVisible = $On } catch { } }

function Out-Row([object[]]$Segments) {
    # A single segment arrives flattened as ('text','Color'); wrap it back.
    if ($Segments -and $Segments.Count -gt 0 -and $Segments[0] -is [string]) { $Segments = @(, $Segments) }
    $len = 0
    foreach ($s in $Segments) {
        $text = [string]$s[0]
        $room = $Width - $len
        if ($room -le 0) { break }
        if ($text.Length -gt $room) { $text = $text.Substring(0, [Math]::Max(0, $room - 3)) + '...' }
        Write-Host $text -NoNewline -ForegroundColor $s[1]
        $len += $text.Length
    }
    $pad = [Math]::Max(0, $Width - $len)
    Write-Host (' ' * $pad)
}

function Out-Rule([string]$Char = '-') { Out-Row @((Seg ('  ' + ($Char * ($Width - 4))) 'DarkCyan')) }

function Get-LightGlyph($h, [bool]$Phase) {
    $glyph = if ($h.Light -eq 'Dark') { $Ring } else { $Dot }
    $color = $ConsoleColorFor[$h.Light]
    if ($h.Blink -and $Phase) { $color = 'DarkGray' }
    return , @($glyph, $color)
}

function Out-VmBlock($h, [bool]$Phase) {
    $g = Get-LightGlyph $h $Phase
    $labelColor = $ConsoleColorFor[$h.Light]
    if ($h.Light -eq 'Dark') { $labelColor = 'Gray' }
    Out-Row @((Seg ('  {0,-10} ' -f $h.Role.ToUpper()) 'White'), (Seg $g[0] $g[1]), (Seg (' {0,-28}' -f $h.Label) $labelColor), (Seg $h.Name 'Cyan'))
    $where = if ($h.IsLocal) { "on $($h.Host) (this server)" } else { "on $($h.Host) (other server)" }
    $hb = if (-not $h.Reachable) { 'heartbeat unknown' } elseif ($h.State -eq 'Running') { "heartbeat $(if ($h.Heartbeat) { $h.Heartbeat } else { 'none' })" } else { "Hyper-V: $($h.State)" }
    $up = if ($h.State -eq 'Running') { "up $(Format-VmsDuration $h.UptimeSeconds)" } else { '' }
    Out-Row @((Seg ('               {0}   {1}   {2}' -f $where, $hb, $up) 'DarkGray'))
    $text = $h.Summary
    if ($text.Length -gt $Width - 16) { $text = $text.Substring(0, $Width - 19) + '...' }
    Out-Row @((Seg ('               ' + $text) 'Gray'))
}

function Show-Screen($Snap, $Row, $Banner, $Avail, [bool]$Phase, $LastResult) {
    Set-CursorVisible $false
    try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
    Out-Rule '='
    $me = "$env:COMPUTERNAME holds the $(([string]$Snap.LocalRole).ToUpper())"
    Out-Row @((Seg '  VM SWITCHER' 'White'), (Seg ('   {0,-40}' -f $me) 'Cyan'), (Seg ('{0,20}' -f (Get-Date -Format 'HH:mm:ss')) 'DarkGray'))
    $pv = $Snap.Peer
    if ($pv) {
        $pt = if ($pv.AppOk) { 'connected' } elseif ($pv.HostPing) { 'app NOT answering' } else { 'UNREACHABLE' }
        $pc = if ($pv.AppOk) { 'Green' } elseif ($pv.HostPing) { 'Yellow' } else { 'Red' }
        Out-Row @((Seg "  Other server $($pv.Address): " 'Gray'), (Seg $pt $pc))
    }
    Out-Rule '='
    Out-VmBlock $Snap.Primary $Phase
    Out-Row @()
    Out-VmBlock $Snap.Secondary $Phase
    Out-Rule
    $bc = switch ($Banner.Level) { 'Ok' { 'Green' } 'Info' { 'Cyan' } 'Warn' { 'Yellow' } default { 'Red' } }
    $words = $Banner.Text -split ' '
    $line = '  '
    foreach ($w in $words) {
        if (($line + $w).Length -gt $Width - 2) { Out-Row @((Seg $line $bc)); $line = '  ' }
        $line += $w + ' '
    }
    Out-Row @((Seg $line $bc))
    $wdText = if (-not $Row) { 'never started' } elseif ($Row.Alive) { "running ($($Row.Mode))" } else { 'NOT RUNNING' }
    $wdColor = if ($Row -and $Row.Alive) { 'Green' } else { 'Red' }
    $af = if ($Banner.Maintenance) { 'PAUSED (maintenance)' } else { 'ACTIVE' }
    $afColor = if ($Banner.Maintenance) { 'Yellow' } else { 'Green' }
    if (-not ($Row -and $Row.Alive)) { $wdText += ' (press W to start it)' }
    Out-Row @((Seg '  Watchdog: ' 'Gray'), (Seg $wdText $wdColor), (Seg '     Auto-failover: ' 'Gray'), (Seg $af $afColor))
    Out-Rule
    foreach ($o in (Get-VmsMenuOptions)) {
        $a = $Avail[$o.Id]
        $title = $o.Title; $hint = $o.Hint
        if ($a.Title) { $title = $a.Title }
        if ($a.Hint) { $hint = $a.Hint }
        if ($o.Id -eq 'ToggleMaintenance') {
            if ($Banner.Maintenance) { $title = 'Resume auto-failover'; $hint = 'Turn automatic failover back ON.' } else { $title = 'Pause auto-failover (maintenance)' }
        }
        $titleColor = if ($a.Title) { 'Yellow' } else { 'White' }
        if ($a.Enabled) { Out-Row @((Seg ('   {0}  ' -f $o.Key) 'Cyan'), (Seg ('{0,-34}' -f $title) $titleColor), (Seg $hint 'DarkGray')) }
        else { Out-Row @((Seg ('   {0}  {1,-34}' -f $o.Key, $title) 'DarkGray'), (Seg ('(' + $a.Reason + ')') 'DarkGray')) }
    }
    Out-Row @((Seg '   0  Exit' 'Cyan'))
    Out-Rule
    if ($LastResult) {
        $c = switch ($LastResult.Result) { 'OK' { 'Green' } 'NOOP' { 'Cyan' } 'INFO' { 'Cyan' } 'REFUSED' { 'Yellow' } default { 'Red' } }
        $msg = "  Last action: $($LastResult.Message)"
        while ($msg.Length -gt 0) {
            $part = if ($msg.Length -gt $Width) { $msg.Substring(0, $Width) } else { $msg }
            Out-Row @((Seg $part $c)); $msg = $msg.Substring($part.Length)
            if ($msg) { $msg = '    ' + $msg }
        }
    } else { Out-Row @((Seg '  Press a number. The screen refreshes every 3 seconds.' 'DarkGray')) }
    Out-Row @(); Out-Row @(); Out-Row @()
    Set-CursorVisible $true
}

function Read-YesNo([string]$Question, [bool]$Default = $false) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    Write-Host ''
    Write-Host "  $Question $hint " -NoNewline -ForegroundColor Yellow
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ($(if ($Default) { 'Y' } else { 'N' })); return $Default }
        if ($k.KeyChar -in 'y', 'Y') { Write-Host 'Y'; return $true }
        if ($k.KeyChar -in 'n', 'N' -or $k.Key -eq 'Escape') { Write-Host 'N'; return $false }
    }
}

function Show-Table([string]$Title, $Table, [string[]]$Columns) {
    Clear-Host
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor White
    Write-Host ('  ' + ('-' * ($Width - 4))) -ForegroundColor DarkCyan
    if ($Table.Rows.Count -eq 0) { Write-Host '  (nothing recorded yet)' -ForegroundColor DarkGray }
    $Table.Rows | Select-Object -Property $Columns | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
    Write-Host '  Press any key to go back.' -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
    Clear-Host
}

function Show-Lines([string]$Title, [string[]]$Lines) {
    Clear-Host
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor White
    Write-Host ('  ' + ('-' * ($Width - 4))) -ForegroundColor DarkCyan
    foreach ($l in $Lines) { Write-Host "  $l" }
    Write-Host ''
    Write-Host '  Press any key to go back.' -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
    Clear-Host
}

function Invoke-Option([int]$Key, [bool]$Interactive) {
    $o = Get-VmsMenuOptions | Where-Object Key -eq $Key
    if (-not $o) { return $null }
    $snap = Get-VmsSnapshot
    $avail = Get-VmsOptionAvailability $snap
    $a = $avail[$o.Id]
    if (-not $a.Enabled -and $o.Id -in 'StartPrimary', 'StartSecondary', 'StopSecondary', 'PlannedStopPrimary') {
        $r = New-VmsResult 'REFUSED' ("Option $Key is not available now: " + $a.Reason)
        Write-VmsEvent -Severity Info -Action $o.Id -Result 'REFUSED' -Message $r.Message
        return $r
    }
    $progress = { param($m) Write-Host "  $m" -ForegroundColor Cyan }
    switch ($o.Id) {
        { $_ -in 'StartPrimary', 'StartSecondary' } {
            $role = if ($o.Id -eq 'StartPrimary') { 'Primary' } else { 'Secondary' }
            if ($Interactive -and $snap.$role.IsFrozen -and -not (Read-YesNo "The $role is ON but not answering (frozen). Restart it now? Unsaved work inside the VM is lost." $false)) { return (New-VmsResult 'NOOP' 'Cancelled. Nothing was changed.') }
            return Invoke-VmsAction -Id $o.Id
        }
        'StopSecondary' {
            if ($Interactive -and -not (Read-YesNo 'Turn OFF the Secondary now (clean shutdown)? The Primary keeps serving users.' $true)) { return (New-VmsResult 'NOOP' 'Cancelled. Nothing was changed.') }
            return Invoke-VmsAction -Id StopSecondary
        }
        'PlannedStopPrimary' {
            $switch = [bool]$Switchover
            if ($Interactive) {
                $switch = Read-YesNo 'Move users to the Secondary first, so there is no gap? (recommended)' $true
                $warn = if ($switch) { 'The Secondary will take over, then the Primary shuts down.' } else { 'NOBODY will serve users until a VM is turned ON again.' }
                if (-not (Read-YesNo "Shut down the Primary now? $warn" $false)) { return (New-VmsResult 'NOOP' 'Cancelled. Nothing was changed.') }
            }
            return Invoke-VmsAction -Id PlannedStopPrimary -SwitchoverFirst:$switch -Progress $progress
        }
        'ToggleMaintenance' {
            $paused = $null -ne (Get-VmsIntent 'maintenance')
            if ($Interactive -and -not $paused -and -not (Read-YesNo 'Pause auto-failover? If the Primary fails, NOTHING will happen automatically.' $false)) { return (New-VmsResult 'NOOP' 'Cancelled. Auto-failover stays active.') }
            return Invoke-VmsAction -Id ToggleMaintenance
        }
        'ShowEvents' {
            if ($Interactive) { Show-Table 'WHAT HAPPENED (newest first)' (Get-VmsEvents 30) @('Time', 'Level', 'By program', 'What happened') }
            else { (Get-VmsEvents 30).Rows | Format-Table Time, Level, 'By program', 'What happened' -AutoSize -Wrap | Out-String -Width 200 | Write-Host }
            return $null
        }
        'ShowHandoffs' {
            if ($Interactive) { Show-Table 'VM HAND-OFF HISTORY (when one VM stopped and the other turned ON)' (Get-VmsHandoffs 20) @('#', 'Type', 'Primary stopped', 'Secondary serving', 'Gap', 'Back to Primary', 'Why') }
            else { (Get-VmsHandoffs 20).Rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
            return $null
        }
        'TestFailover' {
            $r = Invoke-VmsAction -Id TestFailover
            if ($Interactive) { Show-Lines 'FAILOVER TEST (dry run, nothing was changed)' ($r.Message -split "`r?`n"); return (New-VmsResult 'INFO' 'Failover test finished. Nothing was changed.') }
            return $r
        }
        'OpenConsole' {
            $role = $Vm
            if ($Interactive) {
                Write-Host ''
                Write-Host '  Which VM screen? [P]rimary or [S]econdary: ' -NoNewline -ForegroundColor Yellow
                $k = [Console]::ReadKey($true)
                $role = if ($k.KeyChar -in 's', 'S') { 'Secondary' } else { 'Primary' }
                Write-Host $role
            }
            return Invoke-VmsAction -Id OpenConsole -Role $role
        }
        default { return Invoke-VmsAction -Id $o.Id }
    }
}

# ----------------------------------------------------------------------------
# Non-interactive modes
# ----------------------------------------------------------------------------
if ($Option -gt 0) {
    $r = Invoke-Option $Option (-not $Yes -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
    if ($r) { Write-Output "[$($r.Result)] $($r.Message)" }
    Close-Vms
    if ($r -and -not $r.Ok) { exit 1 } else { exit 0 }
}

if ($Snapshot) {
    $snap = Get-VmsSnapshot; $row = Get-VmsWatchdogRow
    Clear-Host
    Show-Screen $snap $row (Get-VmsBanner $snap $row) (Get-VmsOptionAvailability $snap) $false $null
    Close-Vms
    exit 0
}

# ----------------------------------------------------------------------------
# Interactive loop
# ----------------------------------------------------------------------------
Clear-Host
$last = $null
$lastAt = [datetime]::MinValue
$snap = $null
$refreshMs = [int](Get-VmsConfig).CheckIntervalSeconds * 1000
$sw = [Diagnostics.Stopwatch]::StartNew()
$nextRefresh = 0
$phase = $false
try {
    while ($true) {
        if (-not $snap -or $sw.ElapsedMilliseconds -ge $nextRefresh) {
            $snap = Get-VmsSnapshot
            $row = Get-VmsWatchdogRow
            $banner = Get-VmsBanner $snap $row
            $avail = Get-VmsOptionAvailability $snap
            $nextRefresh = $sw.ElapsedMilliseconds + $refreshMs
        }
        if ($last -and ((Get-Date) - $lastAt).TotalSeconds -gt 30) { $last = $null }
        Show-Screen $snap $row $banner $avail $phase $last
        $phase = -not $phase
        # Wait up to 700 ms for a key (blink speed), then redraw.
        $deadline = $sw.ElapsedMilliseconds + 700
        $key = $null
        while ($sw.ElapsedMilliseconds -lt $deadline) {
            if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true); break }
            Start-Sleep -Milliseconds 50
        }
        if (-not $key) { continue }
        if ($key.KeyChar -eq '0' -or $key.Key -eq 'Escape' -or $key.KeyChar -in 'q', 'Q') { break }
        if ($key.KeyChar -in 'w', 'W' -and -not ($row -and $row.Alive)) {
            # The watchdog SERVICE does failover/failback even when this terminal is closed; restart it if someone stopped it.
            $svc = Get-Service -Name 'VMSwitcherWatchdog' -ErrorAction SilentlyContinue
            if (-not $svc) { $last = New-VmsResult 'FAILED' 'The VM Switcher Watchdog service is not installed on this computer. Run the installer.' }
            else {
                try {
                    Start-Service -Name 'VMSwitcherWatchdog' -ErrorAction Stop
                    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
                    Write-VmsEvent -Action 'WatchdogServiceStart' -Result 'OK' -Message 'The watchdog service was started from the terminal. Automatic failover is active again.'
                    $last = New-VmsResult 'OK' 'The watchdog service is running again. Automatic failover and failback are active.'
                } catch { $last = New-VmsResult 'FAILED' "Could not start the watchdog service: $($_.Exception.Message)" }
            }
            $lastAt = Get-Date; $snap = $null; Clear-Host
            continue
        }
        if ($key.KeyChar -match '^[1-9]$') {
            Write-Host ''
            $r = Invoke-Option ([int][string]$key.KeyChar) $true
            if ($r) { $last = $r; $lastAt = Get-Date }
            Clear-Host
            $snap = $null
        }
    }
} finally {
    Set-CursorVisible $true
    Close-Vms
    Clear-Host
    Write-Host 'VM Switcher terminal closed. The watchdog service keeps running in the background.'
}

#requires -Version 5.1
<#
  VM Switcher windowed app (WPF) + tray icon + desktop notifier.
    VMSwitcher.exe            open the window
    VMSwitcher.exe -Tray      start hidden in the tray (used at logon)
  All Hyper-V work runs on background threads so the window never freezes.
#>
param([switch]$Tray, [string]$ScreenshotPath = '', [int]$ScreenshotDelay = 6)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$Src = $PSScriptRoot
$ModulePath = Join-Path $Src 'VMSwitcher.Core.psm1'
Import-Module $ModulePath -Force -DisableNameChecking

# ---- single instance: a second launch just brings the first window forward ----
$createdNew = $false
$suffix = Get-VmsInstanceSuffix
$script:InstanceMutex = New-Object System.Threading.Mutex($true, ('Local\VMSwitcher.GUI' + $suffix), [ref]$createdNew)
$script:ShowSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, ('Local\VMSwitcher.GUI.Show' + $suffix))
if (-not $createdNew) { [void]$script:ShowSignal.Set(); exit 0 }

Initialize-Vms -Source 'GUI'
$Cfg = Get-VmsConfig
$script:LastAlertId = Get-VmsLastAlertId
Close-Vms
$IsDemo = $Cfg.Provider -eq 'Simulated'

# ---------------------------------------------------------------------------
# Build the window from XAML templates
# ---------------------------------------------------------------------------
$xaml = Get-Content (Join-Path $Src 'Gui.xaml') -Raw
$card = Get-Content (Join-Path $Src 'Gui.Card.xaml') -Raw
$cardP = $card.Replace('@R@', 'P').Replace('@COL@', '0').Replace('@ROLE@', 'PRIMARY')
$cardS = $card.Replace('@R@', 'S').Replace('@COL@', '1').Replace('@ROLE@', 'SECONDARY')
$btnTemplate = @'
<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Btn_@ID@" Style="{StaticResource OptBtn}" Margin="6" MinHeight="74" ToolTipService.ShowOnDisabled="True">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border x:Name="Num_@ID@" Width="44" Height="44" CornerRadius="22" Background="#0EA5E9" VerticalAlignment="Center">
      <TextBlock Text="@N@" FontSize="22" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
      <TextBlock x:Name="Title_@ID@" FontSize="17" FontWeight="SemiBold" Foreground="#F1F5F9" TextWrapping="Wrap"/>
      <TextBlock x:Name="Hint_@ID@" FontSize="12.5" Foreground="#94A3B8" TextWrapping="Wrap"/>
    </StackPanel>
  </Grid>
</Button>
'@
$buttons = foreach ($o in (Get-VmsMenuOptions)) { $btnTemplate.Replace('@ID@', $o.Id).Replace('@N@', [string]$o.Key) }
$xaml = $xaml.Replace('<!--CARD_P-->', $cardP).Replace('<!--CARD_S-->', $cardS).Replace('<!--BUTTONS-->', ($buttons -join "`n"))
$Win = [Windows.Markup.XamlReader]::Parse($xaml)

$UI = @{}
foreach ($n in 'DemoBadge', 'WdPill', 'WdText', 'AfPill', 'AfText', 'Clock', 'LastCheck', 'AlertStrip', 'AlertTitle', 'AlertText', 'AlertAck',
    'Banner', 'BannerIcon', 'BannerText', 'DemoPanel', 'ResultText', 'Busy', 'UserText', 'Tabs', 'GridEvents', 'GridHandoffs', 'GridMine', 'GridChanges',
    'Demo_CrashP', 'Demo_FreezeP', 'Demo_FixP', 'Demo_CrashS', 'Demo_Reset', 'Demo_Cut', 'Demo_CutText', 'PeerPill', 'PeerText', 'ThisServer') { $UI[$n] = $Win.FindName($n) }
foreach ($r in 'P', 'S') {
    foreach ($n in 'Card', 'Screen', 'ScreenText', 'Lamp', 'Symbol', 'Label', 'Summary', 'Name', 'Ip', 'Ping', 'State', 'Sub') { $UI["${r}_$n"] = $Win.FindName("${r}_$n") }
    $UI["${r}_Glow"] = $UI["${r}_Lamp"].Effect
}
foreach ($o in (Get-VmsMenuOptions)) {
    foreach ($n in 'Btn', 'Num', 'Title', 'Hint') { $UI["$($n)_$($o.Id)"] = $Win.FindName("$($n)_$($o.Id)") }
    $UI["Title_$($o.Id)"].Text = $o.Title
    $UI["Hint_$($o.Id)"].Text = $o.Hint
}
$UI.UserText.Text = "Signed in as $(Get-VmsActor)"
Initialize-Vms -Source 'GUI'
$LocalRole = Get-VmsLocalRole -Refresh
Close-Vms
$roleWord = switch ($LocalRole) { 'Primary' { 'holds the PRIMARY VM' } 'Secondary' { 'holds the SECONDARY VM' } 'Both' { 'holds BOTH VMs' } default { 'holds NEITHER VM (check settings)' } }
$UI.ThisServer.Text = "This server: $env:COMPUTERNAME - $roleWord"
$Win.Title = "VM Switcher - $env:COMPUTERNAME ($roleWord)"
foreach ($r in @(@('P', 'Primary', 'main VM'), @('S', 'Secondary', 'backup VM'))) {
    $where = if ($LocalRole -eq 'Both' -or $LocalRole -eq $r[1]) { 'on this server' } else { "on server $((Get-VmsVmConfig $r[1]).Host)" }
    $UI["$($r[0])_Sub"].Text = "$($r[2]) - $where"
}
if ($LocalRole -eq 'Both') { $UI.PeerPill.Visibility = 'Collapsed'; $UI.Demo_Cut.Visibility = 'Collapsed' }
if ($IsDemo) { $UI.DemoBadge.Visibility = 'Visible'; $UI.DemoPanel.Visibility = 'Visible' }

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
$BC = New-Object Windows.Media.BrushConverter
function Brush([string]$Hex) { return $BC.ConvertFromString($Hex) }
function Colour([string]$Hex) { return [Windows.Media.ColorConverter]::ConvertFromString($Hex) }
$LampHex = @{ Green = '#22C55E'; Yellow = '#FACC15'; Grey = '#9CA3AF'; Dark = '#1F2937' }
$ScreenHex = @{ Green = '#0F3D24'; Yellow = '#3D3008'; Grey = '#2A2F38'; Dark = '#05080F' }
$LabelHex = @{ Green = '#4ADE80'; Yellow = '#FDE047'; Grey = '#D1D5DB'; Dark = '#94A3B8' }
$CardBorderHex = @{ Green = '#166534'; Yellow = '#854D0E'; Grey = '#4B5563'; Dark = '#1E2A44' }

# ---------------------------------------------------------------------------
# Background work (runspace pool)
# ---------------------------------------------------------------------------
$iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
$iss.ImportPSModule(@($ModulePath))
$Pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
$Pool.Open()
$Sync = [hashtable]::Synchronized(@{ Progress = '' })

function Start-Bg([scriptblock]$Script, [hashtable]$Params = @{}) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($Script)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    return @{ PS = $ps; Handle = $ps.BeginInvoke() }
}
function Receive-Bg($Job) {
    try {
        $out = $Job.PS.EndInvoke($Job.Handle)
        $err = @($Job.PS.Streams.Error)
        if ($out.Count -gt 0) { return $out[$out.Count - 1] }
        if ($err.Count -gt 0) { return [pscustomobject]@{ Error = $err[0].ToString() } }
        return $null
    } catch { return [pscustomobject]@{ Error = $_.Exception.Message } }
    finally { $Job.PS.Dispose() }
}

$SnapshotScript = {
    param($LastAlertId)
    Initialize-Vms -Source 'GUI'
    try {
        $snap = Get-VmsSnapshot
        $row = Get-VmsWatchdogRow
        $peerOk = (-not $snap.Peer) -or $snap.Peer.AppOk
        $events = Get-VmsMergedEvents 200 -LocalOnly:(-not $peerOk)
        $mine = $events.Clone()
        foreach ($e in $events.Rows) { if ([string]$e['By program'] -in 'GUI', 'Terminal') { $mine.ImportRow($e) } }
        [pscustomobject]@{
            Error    = $null
            Snap     = $snap
            Row      = $row
            Banner   = (Get-VmsBanner $snap $row)
            Avail    = (Get-VmsOptionAvailability $snap)
            Alerts   = (Get-VmsAlertsSince $LastAlertId)
            Events   = $events
            Handoffs = $(if ($peerOk -or (Test-VmsKeepsHandoffs)) { Get-VmsHandoffsAnywhere 100 } else { $null })
            Mine     = $mine
            Changes  = (Get-VmsTransitions 300)
        }
    } catch { [pscustomobject]@{ Error = $_.Exception.Message } }
    finally { Close-Vms }
}

$ActionScript = {
    param($Id, $Switch, $Role, $On, $Sync)
    Initialize-Vms -Source 'GUI'
    try {
        $progress = { param($m) $Sync.Progress = [string]$m }.GetNewClosure()
        $p = @{ Id = $Id; Progress = $progress; Role = $Role }
        if ($Switch) { $p.SwitchoverFirst = $true }
        if ($null -ne $On) { $p.On = [bool]$On }
        Invoke-VmsAction @p
    } catch { New-VmsResult 'FAILED' $_.Exception.Message }
    finally { Close-Vms; $Sync.Progress = '' }
}

$DemoScript = {
    param($What)
    Initialize-Vms -Source 'GUI'
    try {
        # The simulated VM lives on one of the two (simulated) servers: change it there.
        function Set-DrillVm([string]$Role, [hashtable]$P) {
            if (Test-VmsRoleIsLocal $Role) { $P.Role = $Role; Set-VmsSimVm @P }
            else { $b = @{ Role = $Role }; foreach ($k in $P.Keys) { $b[$k] = $P[$k] }; [void](Invoke-VmsPeer -Method POST -Path '/vms/sim' -Body $b) }
        }
        switch ($What) {
            'CrashP' { Set-DrillVm Primary @{ State = 'Off' }; $m = 'Fire drill: the Primary was crashed (turned OFF without warning).' }
            'FreezeP' { Set-DrillVm Primary @{ State = 'Running'; PingOk = $false; UptimeSeconds = 9999 }; $m = 'Fire drill: the Primary is frozen. It stays ON in Hyper-V but its heartbeat stopped.' }
            'FixP' { Set-DrillVm Primary @{ PingOk = $true }; $m = 'Fire drill: the Primary reports its heartbeat again.' }
            'CrashS' { Set-DrillVm Secondary @{ State = 'Off' }; $m = 'Fire drill: the Secondary was crashed.' }
            'Cut' {
                $cut = -not (Test-VmsSimNetworkCut)
                Set-VmsSimNetworkCut $cut
                $m = if ($cut) { 'Fire drill: the network between the two servers is CUT (from this server''s point of view).' } else { 'Fire drill: the network between the two servers is back.' }
            }
            'Reset' {
                Set-VmsSimNetworkCut $false
                Set-DrillVm Primary @{ State = 'Running'; PingOk = $true; UptimeSeconds = 18000 }
                Set-DrillVm Secondary @{ State = 'Off' }
                Clear-VmsIntent 'planned_stop' -Replicate
                $m = 'Fire drill reset: Primary ON, Secondary OFF, network OK.'
            }
        }
        Write-VmsEvent -Action 'FireDrill' -Message $m
        New-VmsResult 'INFO' $m
    } catch { New-VmsResult 'FAILED' $_.Exception.Message }
    finally { Close-Vms }
}

# ---------------------------------------------------------------------------
# Tray icon + notifications
# ---------------------------------------------------------------------------
function New-DotIcon([string]$Hex) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $c = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $c), 3, 3, 26, 26)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2), 3, 3, 26, 26)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$TrayIcons = @{ Green = (New-DotIcon '#22C55E'); Amber = (New-DotIcon '#F59E0B'); Red = (New-DotIcon '#EF4444'); Grey = (New-DotIcon '#9CA3AF') }

$appIconPath = Join-Path (Split-Path $Src -Parent) 'assets\vmswitcher.ico'
if (-not (Test-Path $appIconPath)) { $appIconPath = Join-Path $Src 'vmswitcher.ico' }
if (Test-Path $appIconPath) { try { $Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$appIconPath) } catch { } }

$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Icon = $TrayIcons.Grey
$NotifyIcon.Text = 'VM Switcher'
$NotifyIcon.Visible = $true
$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$TrayMenu.Items.Add('Open VM Switcher', $null, { Show-Main })
[void]$TrayMenu.Items.Add('-')
[void]$TrayMenu.Items.Add('Close the app (watchdog keeps running)', $null, { Exit-App })
$NotifyIcon.ContextMenuStrip = $TrayMenu
$NotifyIcon.add_DoubleClick({ Show-Main })
$NotifyIcon.add_BalloonTipClicked({ Show-Main })

function Show-Main {
    $Win.Show()
    if ($Win.WindowState -eq 'Minimized') { $Win.WindowState = 'Normal' }
    $Win.Topmost = $true; $Win.Activate() | Out-Null; $Win.Topmost = $false
}

function Invoke-AlertSound([string]$Severity) {
    if ($env:VMSWITCHER_MUTE) { return }
    try {
        if ($Severity -eq 'Critical') {
            $wav = Join-Path $env:windir ('Media\' + $Cfg.AlertSound)
            if (Test-Path $wav) { (New-Object System.Media.SoundPlayer $wav).Play() } else { [System.Media.SystemSounds]::Hand.Play() }
        } elseif ($Severity -eq 'Warning') { [System.Media.SystemSounds]::Exclamation.Play() }
        else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch { }   # servers often have no audio device; the pop-up and red strip still show
}

Add-Type -Namespace VmsWin -Name Flash -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
public static void Start(IntPtr h) { var f = new FLASHWINFO(); f.cbSize = (uint)Marshal.SizeOf(f); f.hwnd = h; f.dwFlags = 3 | 12; f.uCount = 0; f.dwTimeout = 0; FlashWindowEx(ref f); }
'@

function Request-Attention {
    <# Never steal focus or un-minimize. If the window is not in front, flash its taskbar button until opened. #>
    try {
        if ($Win.IsVisible -and -not $Win.IsActive) {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Win).Handle
            if ($hwnd -ne [IntPtr]::Zero) { [VmsWin.Flash]::Start($hwnd) }
        }
    } catch { }
}

function Show-Alert($Row) {
    $sev = [string]$Row.severity
    $icon = switch ($sev) { 'Critical' { 'Error' } 'Warning' { 'Warning' } default { 'Info' } }
    $NotifyIcon.ShowBalloonTip(15000, [string]$Row.title, [string]$Row.message, $icon)
    Invoke-AlertSound $sev
    if ($sev -in 'Critical', 'Warning') {
        $UI.AlertTitle.Text = "$($Row.title)   ($(([string]$Row.ts).Substring(11)))"
        $UI.AlertText.Text = [string]$Row.message
        $UI.AlertStrip.Background = Brush $(if ($sev -eq 'Critical') { '#7F1D1D' } else { '#713F12' })
        $UI.AlertStrip.BorderBrush = Brush $(if ($sev -eq 'Critical') { '#F87171' } else { '#FBBF24' })
        $UI.AlertStrip.Visibility = 'Visible'
        Request-Attention
    }
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
$script:Blink = @{ P = $false; S = $false }
$script:BlinkPhase = $false
$script:Latest = $null
$script:GridSig = @{}

function Set-Card([string]$R, $H) {
    $light = $H.Light
    $UI["${R}_Lamp"].Fill = Brush $LampHex[$light]
    $UI["${R}_Glow"].Color = Colour $LampHex[$light]
    $UI["${R}_Glow"].Opacity = $(if ($light -eq 'Dark') { 0 } elseif ($light -eq 'Grey') { 0.5 } else { 0.95 })
    $UI["${R}_Lamp"].Stroke = Brush $(if ($light -eq 'Dark') { '#334155' } else { '#0B1220' })
    $UI["${R}_Screen"].Fill = Brush $ScreenHex[$light]
    $UI["${R}_ScreenText"].Text = $(switch ($H.ShortLabel) { 'OK' { 'OK' } 'SUSPENDED' { 'zzz' } 'OFF' { '' } 'ERROR' { '!' } 'UNREACHABLE' { '?' } default { '...' } })
    $UI["${R}_ScreenText"].Foreground = Brush $LabelHex[$light]
    $UI["${R}_Label"].Text = $H.Label
    $UI["${R}_Label"].FontSize = $(if ($H.ShortLabel.Length -gt 9) { 17 } else { 21 })
    $UI["${R}_Label"].Foreground = Brush $LabelHex[$light]
    $UI["${R}_Symbol"].Text = $H.Symbol
    $UI["${R}_Symbol"].Foreground = Brush $LabelHex[$light]
    $UI["${R}_Summary"].Text = $H.Summary
    $UI["${R}_Name"].Text = $H.Name
    $UI["${R}_Ip"].Text = $(if ($H.IsLocal) { "$($H.Host) (this server)" } else { "$($H.Host) (other server)" })
    $UI["${R}_Ping"].Text = $(if (-not $H.Reachable) { 'unknown (cannot reach that server)' } elseif ($H.State -ne 'Running') { 'none (VM not running)' } elseif ($H.Heartbeat) { $H.Heartbeat } else { 'no heartbeat' })
    $state = $(if ($H.Reachable) { $H.State } else { 'unknown' })
    if ($H.State -eq 'Running') { $state += ", up $(Format-VmsDuration $H.UptimeSeconds)" }
    $UI["${R}_State"].Text = $state
    $UI["${R}_Card"].BorderBrush = Brush $CardBorderHex[$light]
    $script:Blink[$R] = [bool]$H.Blink
    if (-not $H.Blink) { $UI["${R}_Lamp"].Opacity = 1 }
}

function Set-Grid($Grid, [string]$Key, $Table) {
    if ($null -eq $Table) { return }
    $sig = "$($Table.Rows.Count)|" + $(if ($Table.Rows.Count -gt 0) { ($Table.Rows[0].ItemArray -join '|') } else { '' })
    if ($script:GridSig[$Key] -eq $sig) { return }
    $script:GridSig[$Key] = $sig
    $Grid.ItemsSource = $Table.DefaultView
}

function Update-View($D) {
    if ($D.Error) {
        $UI.BannerText.Text = "Cannot read the VM status: $($D.Error)"
        $UI.Banner.Background = Brush '#3B1C22'; $UI.Banner.BorderBrush = Brush '#B91C1C'
        $UI.BannerIcon.Text = [string][char]0x26A0; $UI.BannerIcon.Foreground = Brush '#F87171'
        $NotifyIcon.Icon = $TrayIcons.Grey
        return
    }
    $script:Latest = $D
    Set-Card 'P' $D.Snap.Primary
    Set-Card 'S' $D.Snap.Secondary

    $b = $D.Banner
    $style = switch ($b.Level) {
        'Ok' { @('#052E1A', '#166534', [string][char]0x2714, '#4ADE80') }
        'Info' { @('#0C2A40', '#0369A1', [string][char]0x2139, '#7DD3FC') }
        'Warn' { @('#3A2A06', '#B45309', [string][char]0x26A0, '#FBBF24') }
        default { @('#3B1C22', '#B91C1C', [string][char]0x2716, '#F87171') }
    }
    $UI.Banner.Background = Brush $style[0]; $UI.Banner.BorderBrush = Brush $style[1]
    $UI.BannerIcon.Text = $style[2]; $UI.BannerIcon.Foreground = Brush $style[3]
    $UI.BannerText.Text = $b.Text

    $row = $D.Row
    $script:WatchdogDown = -not ($row -and $row.Alive)
    if (-not $row) { $UI.WdText.Text = 'Watchdog: never started - click to start'; $UI.WdPill.Background = Brush '#7F1D1D' }
    elseif ($row.Alive) {
        $mode = if ($row.Mode -eq 'FailedOver') { 'failover active' } else { 'running' }
        $UI.WdText.Text = "Watchdog: $mode"; $UI.WdPill.Background = Brush $(if ($row.Mode -eq 'FailedOver') { '#92400E' } else { '#14532D' })
    } else { $UI.WdText.Text = 'Watchdog: NOT RUNNING - click to start'; $UI.WdPill.Background = Brush '#7F1D1D' }
    $UI.WdPill.Cursor = $(if ($script:WatchdogDown) { [Windows.Input.Cursors]::Hand } else { [Windows.Input.Cursors]::Arrow })
    $pv = $D.Snap.Peer
    if ($pv) {
        if ($pv.AppOk) {
            $pw = Get-VmsProp $pv.Status 'Watchdog'
            $pwOk = $pw -and (Get-VmsProp $pw 'Alive' $false)
            $UI.PeerText.Text = "Other server $($pv.Address): " + $(if ($pwOk) { 'connected' } else { 'connected, its watchdog is NOT running' })
            $UI.PeerPill.Background = Brush $(if ($pwOk) { '#14532D' } else { '#92400E' })
        } elseif ($pv.HostPing) { $UI.PeerText.Text = "Other server $($pv.Address): app not answering"; $UI.PeerPill.Background = Brush '#92400E' }
        else { $UI.PeerText.Text = "Other server $($pv.Address): UNREACHABLE"; $UI.PeerPill.Background = Brush '#7F1D1D' }
        $UI.Demo_CutText.Text = $(if ($pv.Problem -like '*fire drill*') { 'Restore the network' } else { 'Cut the network to the other server' })
    }
    if ($b.Maintenance) { $UI.AfText.Text = 'Auto-failover: PAUSED'; $UI.AfPill.Background = Brush '#92400E' }
    else { $UI.AfText.Text = 'Auto-failover: ON'; $UI.AfPill.Background = Brush '#14532D' }
    $UI.LastCheck.Text = "checked $($D.Snap.Time.ToString('HH:mm:ss'))"

    foreach ($o in (Get-VmsMenuOptions)) {
        $a = $D.Avail[$o.Id]
        $btn = $UI["Btn_$($o.Id)"]
        $title = $o.Title; $hint = $o.Hint
        if ($a.Title) { $title = $a.Title }
        if ($a.Hint) { $hint = $a.Hint }
        if ($o.Id -eq 'ToggleMaintenance' -and $b.Maintenance) { $title = 'Resume auto-failover'; $hint = 'Turn automatic failover back ON.' }
        $UI["Title_$($o.Id)"].Text = $title
        if ($script:BusyJob) { $btn.IsEnabled = $false; continue }
        $btn.IsEnabled = [bool]$a.Enabled
        if ($a.Enabled) {
            $UI["Hint_$($o.Id)"].Text = $hint; $UI["Hint_$($o.Id)"].Foreground = Brush $(if ($a.Title) { '#FBBF24' } else { '#94A3B8' })
            $UI["Num_$($o.Id)"].Background = Brush $(if ($a.Title) { '#D97706' } else { '#0EA5E9' }); $btn.ToolTip = $hint
        } else {
            $UI["Hint_$($o.Id)"].Text = $a.Reason; $UI["Hint_$($o.Id)"].Foreground = Brush '#FBBF24'
            $UI["Num_$($o.Id)"].Background = Brush '#475569'; $btn.ToolTip = $a.Reason
        }
    }

    # Tray colour = overall health at a glance
    $p = $D.Snap.Primary; $s = $D.Snap.Secondary
    if ($b.Level -eq 'Bad') { $NotifyIcon.Icon = $TrayIcons.Red; $t = 'NOBODY IS SERVING' }
    elseif ($p.IsHealthy -and $s.Reachable -and -not $b.Maintenance -and $row -and $row.Alive) { $NotifyIcon.Icon = $TrayIcons.Green; $t = 'All good' }
    elseif ($p.IsHealthy -or $s.IsHealthy) { $NotifyIcon.Icon = $TrayIcons.Amber; $t = $(if ($p.IsHealthy) { 'Check needed' } else { 'Running on Secondary' }) }
    else { $NotifyIcon.Icon = $TrayIcons.Grey; $t = 'Changing state' }
    $NotifyIcon.Text = "VM Switcher - $t"

    Set-Grid $UI.GridEvents 'events' $D.Events
    Set-Grid $UI.GridHandoffs 'handoffs' $D.Handoffs
    Set-Grid $UI.GridMine 'mine' $D.Mine
    Set-Grid $UI.GridChanges 'changes' $D.Changes

    if ($D.Alerts -and $D.Alerts.Rows.Count -gt 0) {
        foreach ($a in $D.Alerts.Rows) {
            if ([long]$a.id -gt $script:LastAlertId) { $script:LastAlertId = [long]$a.id; Show-Alert $a }
        }
    }
}

# Wide text columns wrap instead of running off screen.
$WrapStyle = New-Object Windows.Style ([Windows.Controls.TextBlock])
$WrapStyle.Setters.Add((New-Object Windows.Setter ([Windows.Controls.TextBlock]::TextWrappingProperty), ([Windows.TextWrapping]::Wrap)))
foreach ($g in $UI.GridEvents, $UI.GridHandoffs, $UI.GridMine, $UI.GridChanges) {
    $g.Add_AutoGeneratingColumn({
            param($grid, $e)
            if ($e.PropertyName -in 'What happened', 'Why', 'Change') {
                $e.Column.Width = New-Object Windows.Controls.DataGridLength(1, [Windows.Controls.DataGridLengthUnitType]::Star)
                $e.Column.ElementStyle = $WrapStyle
            }
        })
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
$script:BusyJob = $null
$script:WatchdogDown = $false
$script:SnapJob = $null
$script:DemoJob = $null
$script:LastSnapAt = [datetime]::MinValue

function Set-Result([string]$Result, [string]$Message) {
    $UI.ResultText.Text = "$(Get-Date -Format 'HH:mm:ss')  -  $Message"
    $UI.ResultText.Foreground = Brush $(switch ($Result) { 'OK' { '#4ADE80' } 'NOOP' { '#7DD3FC' } 'INFO' { '#7DD3FC' } 'REFUSED' { '#FBBF24' } 'WORKING' { '#E2E8F0' } default { '#F87171' } })
}

function Ask([string]$Text, [string]$Title, [string]$Buttons = 'YesNo', [string]$Icon = 'Question') {
    return [Windows.MessageBox]::Show($Win, $Text, $Title, $Buttons, $Icon)
}

function Start-Action([string]$Id, [string]$WorkingText, [bool]$Switch = $false, [string]$Role = 'Primary', $On = $null) {
    if ($script:BusyJob) { return }
    Set-Result 'WORKING' $WorkingText
    $UI.Busy.Visibility = 'Visible'
    foreach ($o in (Get-VmsMenuOptions)) { $UI["Btn_$($o.Id)"].IsEnabled = $false }
    $script:BusyId = $Id
    $script:BusyJob = Start-Bg $ActionScript @{ Id = $Id; Switch = $Switch; Role = $Role; On = $On; Sync = $Sync }
}

function Invoke-Option([string]$Id) {
    try {
        if ($script:BusyJob) { return }
        $btn = $UI["Btn_$Id"]
        if ($btn -and -not $btn.IsEnabled -and $Id -notin 'ShowEvents', 'ShowHandoffs', 'TestFailover', 'OpenConsole') {
            Set-Result 'REFUSED' ([string]$btn.ToolTip); return
        }
        switch ($Id) {
            { $_ -in 'StartPrimary', 'StartSecondary' } {
                $role = if ($Id -eq 'StartPrimary') { 'Primary' } else { 'Secondary' }
                $frozen = $script:Latest -and $script:Latest.Snap.$role.IsFrozen
                if ($frozen) {
                    $r = Ask "The $role is ON in Hyper-V but does not answer on the network. It looks frozen.`n`nRestart it now? This is like pressing the reset button: unsaved work inside the VM is lost." "Restart the $role" 'YesNo' 'Warning'
                    if ($r -eq 'Yes') { Start-Action $Id "Restarting the $role..." } else { Set-Result 'NOOP' 'Cancelled. Nothing was changed.' }
                } else { Start-Action $Id "Turning ON the $role..." }
            }
            'StopSecondary' {
                $r = Ask "Turn OFF the Secondary now?`n`nThe Primary is ON and keeps serving users. Windows inside the Secondary shuts down cleanly, then the VM is OFF." 'Option 3 - Turn OFF Secondary'
                if ($r -eq 'Yes') { Start-Action $Id 'Turning OFF the Secondary...' } else { Set-Result 'NOOP' 'Cancelled. Nothing was changed.' }
            }
            'PlannedStopPrimary' {
                $r = Ask ("Planned stop of the Primary.`n`n" +
                    "YES  = move users to the Secondary first, then shut down the Primary. (Recommended: no gap.)`n" +
                    "NO   = shut down the Primary only. NOBODY serves users until a VM is turned ON.`n" +
                    "CANCEL = do nothing.`n`nNo failover alarm is raised in either case.") 'Option 4 - Planned stop of Primary' 'YesNoCancel' 'Warning'
                if ($r -eq 'Yes') { Start-Action $Id 'Planned switchover: turning ON the Secondary first...' $true }
                elseif ($r -eq 'No') {
                    $c = Ask 'Are you sure? Users will lose the service until a VM is turned ON again.' 'Confirm shutdown' 'YesNo' 'Warning'
                    if ($c -eq 'Yes') { Start-Action $Id 'Shutting down the Primary...' $false } else { Set-Result 'NOOP' 'Cancelled. Nothing was changed.' }
                } else { Set-Result 'NOOP' 'Cancelled. Nothing was changed.' }
            }
            'ToggleMaintenance' {
                $paused = $script:Latest -and $script:Latest.Banner.Maintenance
                if ($paused) { Start-Action 'SetMaintenance' 'Resuming auto-failover...' $false 'Primary' $false }
                else {
                    $r = Ask "Pause auto-failover (maintenance mode)?`n`nIf the Primary fails while paused, NOTHING happens automatically. Use this while you patch or restart the Primary on purpose, and resume it afterwards." 'Option 5 - Pause auto-failover' 'YesNo' 'Warning'
                    if ($r -eq 'Yes') { Start-Action 'SetMaintenance' 'Pausing auto-failover...' $false 'Primary' $true } else { Set-Result 'NOOP' 'Cancelled. Auto-failover stays ON.' }
                }
            }
            'ShowEvents' { $UI.Tabs.SelectedIndex = 0; $UI.GridEvents.BringIntoView(); Set-Result 'INFO' 'Showing what happened, newest first.' }
            'ShowHandoffs' { $UI.Tabs.SelectedIndex = 1; $UI.GridHandoffs.BringIntoView(); Set-Result 'INFO' 'Showing when one VM stopped and the other turned ON.' }
            'TestFailover' { Start-Action $Id 'Running the failover test (dry run)...' }
            'OpenConsole' {
                $r = Ask "Which VM screen do you want to see?`n`nYES = Primary`nNO = Secondary" 'Option 9 - Open VM console' 'YesNoCancel'
                if ($r -eq 'Yes') { Start-Action $Id 'Opening the Primary screen...' $false 'Primary' }
                elseif ($r -eq 'No') { Start-Action $Id 'Opening the Secondary screen...' $false 'Secondary' }
            }
        }
    } catch { Set-Result 'FAILED' "Something went wrong: $($_.Exception.Message)" }
}

foreach ($o in (Get-VmsMenuOptions)) {
    $id = $o.Id
    $UI["Btn_$id"].Add_Click({ Invoke-Option $this.Name.Substring(4) })
}

$UI.AlertAck.Add_Click({ $UI.AlertStrip.Visibility = 'Collapsed' })

# The watchdog SERVICE does failover/failback, with or without this window. If someone stopped it, one click restarts it.
$UI.WdPill.ToolTip = 'The VM Switcher Watchdog service does the automatic failover and failback. It keeps running when this window or the terminal is closed.'
$ServiceScript = {
    Initialize-Vms -Source 'GUI'
    try {
        $svc = Get-Service -Name 'VMSwitcherWatchdog' -ErrorAction SilentlyContinue
        if (-not $svc) { New-VmsResult 'FAILED' 'The VM Switcher Watchdog service is not installed on this computer (demo/test copy). Run the installer.' }
        else {
            Start-Service -Name 'VMSwitcherWatchdog' -ErrorAction Stop
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
            Write-VmsEvent -Action 'WatchdogServiceStart' -Result 'OK' -Message 'The watchdog service was started from the VM Switcher window. Automatic failover is active again.'
            New-VmsResult 'OK' 'The watchdog service is running again. Automatic failover and failback are active.'
        }
    } catch { New-VmsResult 'FAILED' "Could not start the watchdog service: $($_.Exception.Message)" }
    finally { Close-Vms }
}
$UI.WdPill.Add_MouseLeftButtonUp({
        if (-not $script:WatchdogDown -or $script:BusyJob) { return }
        $r = Ask "The VM Switcher Watchdog service on this server is NOT running, so there is no automatic failover or failback from this server.`n`nStart it now?" 'Start the watchdog service' 'YesNo' 'Warning'
        if ($r -eq 'Yes') {
            Set-Result 'WORKING' 'Starting the watchdog service...'
            $UI.Busy.Visibility = 'Visible'
            $script:BusyId = 'StartService'
            $script:BusyJob = Start-Bg $ServiceScript
        }
    })

$Win.Add_KeyDown({
        param($s, $e)
        $k = [string]$e.Key
        $n = 0
        if ($k -match '^D([1-9])$') { $n = [int]$Matches[1] } elseif ($k -match '^NumPad([1-9])$') { $n = [int]$Matches[1] }
        if ($n -gt 0) {
            $o = Get-VmsMenuOptions | Where-Object Key -eq $n
            if ($o) {
                if (-not $UI["Btn_$($o.Id)"].IsEnabled -and $o.Id -in 'StartPrimary', 'StartSecondary', 'StopSecondary', 'PlannedStopPrimary') { Set-Result 'REFUSED' ("Option ${n}: " + [string]$UI["Btn_$($o.Id)"].ToolTip) }
                else { Invoke-Option $o.Id }
            }
            $e.Handled = $true
        }
    })

foreach ($d in @(@('Demo_CrashP', 'CrashP'), @('Demo_FreezeP', 'FreezeP'), @('Demo_FixP', 'FixP'), @('Demo_CrashS', 'CrashS'), @('Demo_Cut', 'Cut'), @('Demo_Reset', 'Reset'))) {
    $UI[$d[0]].Tag = $d[1]
    $UI[$d[0]].Add_Click({ if (-not $script:DemoJob) { $script:DemoJob = Start-Bg $DemoScript @{ What = [string]$this.Tag } } })
}

# ---------------------------------------------------------------------------
# Timers: polling (250 ms), refresh every CheckIntervalSeconds, blink (500 ms)
# ---------------------------------------------------------------------------
$Poll = New-Object Windows.Threading.DispatcherTimer
$Poll.Interval = [TimeSpan]::FromMilliseconds(250)
$Poll.Add_Tick({
        try {
            $UI.Clock.Text = (Get-Date).ToString('HH:mm:ss')
            if ($script:ShowSignal.WaitOne(0)) { Show-Main }

            if ($script:SnapJob -and $script:SnapJob.Handle.IsCompleted) {
                $d = Receive-Bg $script:SnapJob; $script:SnapJob = $null
                if ($d) { Update-View $d }
            }
            if ($script:DemoJob -and $script:DemoJob.Handle.IsCompleted) {
                $r = Receive-Bg $script:DemoJob; $script:DemoJob = $null
                if ($r) { Set-Result $r.Result $r.Message }
                $script:LastSnapAt = [datetime]::MinValue
            }
            if ($script:BusyJob) {
                if ($Sync.Progress) { Set-Result 'WORKING' $Sync.Progress }
                if ($script:BusyJob.Handle.IsCompleted) {
                    $r = Receive-Bg $script:BusyJob; $script:BusyJob = $null
                    $UI.Busy.Visibility = 'Collapsed'
                    if ($r -and $r.PSObject.Properties['Result']) {
                        if ($script:BusyId -eq 'TestFailover') {
                            Set-Result 'INFO' 'Failover test finished. Nothing was changed.'
                            [void](Ask $r.Message 'Option 8 - Failover test (dry run, nothing was changed)' 'OK' 'Information')
                        } else { Set-Result $r.Result $r.Message }
                    } elseif ($r -and $r.Error) { Set-Result 'FAILED' $r.Error }
                    $script:LastSnapAt = [datetime]::MinValue
                }
            }
            if (-not $script:SnapJob -and ((Get-Date) - $script:LastSnapAt).TotalSeconds -ge [int]$Cfg.CheckIntervalSeconds) {
                $script:LastSnapAt = Get-Date
                $script:SnapJob = Start-Bg $SnapshotScript @{ LastAlertId = $script:LastAlertId }
            }
        } catch { try { Set-Result 'FAILED' "Display error: $($_.Exception.Message)" } catch { } }
    })

$BlinkTimer = New-Object Windows.Threading.DispatcherTimer
$BlinkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$BlinkTimer.Add_Tick({
        $script:BlinkPhase = -not $script:BlinkPhase
        foreach ($r in 'P', 'S') {
            if ($script:Blink[$r]) { $UI["${r}_Lamp"].Opacity = $(if ($script:BlinkPhase) { 0.25 } else { 1 }) }
        }
    })

# Closing the window hides it to the tray; the app keeps showing alerts.
$script:ReallyExit = $false
$script:TrayHintShown = $false
$Win.Add_Closing({
        param($s, $e)
        if (-not $script:ReallyExit) {
            $e.Cancel = $true
            $Win.Hide()
            if (-not $script:TrayHintShown) {
                $script:TrayHintShown = $true
                $NotifyIcon.ShowBalloonTip(6000, 'VM Switcher is still here', 'It keeps showing alerts from the tray. Double-click the coloured dot to open it again.', 'Info')
            }
        }
    })

function Exit-App {
    $script:ReallyExit = $true
    $Poll.Stop(); $BlinkTimer.Stop()
    $NotifyIcon.Visible = $false; $NotifyIcon.Dispose()
    $Win.Close()
    $App.Shutdown()
}

# Optional: save a screenshot of the window (used for documentation and checkpoints).
if ($ScreenshotPath) {
    $Shot = New-Object Windows.Threading.DispatcherTimer
    $Shot.Interval = [TimeSpan]::FromSeconds($ScreenshotDelay)
    $Shot.Add_Tick({
            $Shot.Stop()
            try {
                $content = $Win.Content
                $w = [int]$content.ActualWidth; $h = [int]$content.ActualHeight
                $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                $bg = New-Object Windows.Media.DrawingVisual
                $dc = $bg.RenderOpen(); $dc.DrawRectangle((Brush '#0B1220'), $null, (New-Object Windows.Rect(0, 0, $w, $h))); $dc.Close()
                $rtb.Render($bg); $rtb.Render($content)
                $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs = [IO.File]::Create($ScreenshotPath); $enc.Save($fs); $fs.Close()
            } catch { }
            Exit-App
        })
    $Shot.Start()
}

$App = New-Object Windows.Application
$App.ShutdownMode = 'OnExplicitShutdown'
$Poll.Start(); $BlinkTimer.Start()
if (-not $Tray) { $Win.Show() } else { $NotifyIcon.ShowBalloonTip(5000, 'VM Switcher', 'Watching both VMs from the tray. Double-click the dot to open.', 'Info') }
try { [void]$App.Run() }
finally {
    try { $NotifyIcon.Dispose() } catch { }
    try { $Pool.Close() } catch { }
    try { $script:InstanceMutex.ReleaseMutex() } catch { }
}

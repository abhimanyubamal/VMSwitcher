# Two-server demo on ONE PC: starts two watchdogs ("server A" = Primary's server, "server B" = Secondary's
# server) and, unless -NoGui, a VM Switcher window for each. Uses simulated VMs; nothing real is touched.
#   powershell -ExecutionPolicy Bypass -File tests\Start-TwoServerDemo.ps1
#   ... -Shot <folder> -ShotDelay 10 -Scenario Crash|Silence|None    (saves screenshots, then exits)
param([switch]$NoGui, [string]$Shot = '', [int]$ShotDelay = 10, [ValidateSet('None', 'Crash', 'Silence')][string]$Scenario = 'None', [string]$Base = (Join-Path $env:TEMP 'vms-demo2'))
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\src'
$servers = [ordered]@{
    A = @{ Role = 'Primary'; Listen = 47361; Peer = 47362 }
    B = @{ Role = 'Secondary'; Listen = 47362; Peer = 47361 }
}
function Use-Server([string]$Id) {
    $h = $servers[$Id]
    $env:VMSWITCHER_HOME = "$Base\$Id"; $env:VMSWITCHER_LOCALROLE = $h.Role; $env:VMSWITCHER_INSTANCE = $Id
    $dir = Join-Path $Base $Id
    if (-not (Test-Path (Join-Path $dir 'config.json'))) { New-Item -ItemType Directory -Force $dir | Out-Null; Set-Content (Join-Path $dir 'config.json') '{ "Primary": { "Name": "DEMO-PRIMARY", "Host": "10.0.0.1" }, "Secondary": { "Name": "DEMO-SECONDARY", "Host": "10.0.0.2" } }' -Encoding ASCII }
    $env:VMSWITCHER_LISTENPORT = [string]$h.Listen; $env:VMSWITCHER_PEERPORT = [string]$h.Peer; $env:VMSWITCHER_PEERADDRESS = '127.0.0.1'
    $env:VMSWITCHER_PROVIDER = 'Simulated'; $env:VMSWITCHER_KEY = 'demo-shared-key'
    if ($Shot) { $env:VMSWITCHER_MUTE = '1' }
}
if (Test-Path $Base) { Remove-Item $Base -Recurse -Force }
$procs = @()
foreach ($id in $servers.Keys) {
    Use-Server $id
    $procs += Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$src\Watchdog.ps1`"" -PassThru -WindowStyle Hidden
}
Start-Sleep -Seconds 5
$guis = @{}
if (-not $NoGui) {
    foreach ($id in $servers.Keys) {
        Use-Server $id
        $args = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$src\Gui.ps1`""
        if ($Shot) { $args += " -ScreenshotPath `"$Shot\gui2-$Scenario-$id.png`" -ScreenshotDelay $ShotDelay" }
        $guis[$id] = Start-Process powershell.exe -ArgumentList $args -PassThru
    }
}
if ($Scenario -ne 'None') {
    Start-Sleep -Seconds 3
    Import-Module (Join-Path $src 'VMSwitcher.Core.psm1') -Force -DisableNameChecking
    if ($Scenario -eq 'Crash') { Use-Server A; Initialize-Vms -Source 'Test'; Set-VmsSimVm -Role Primary -State Off; Close-Vms }
    if ($Scenario -eq 'Silence') { Stop-Process -Id $procs[0].Id -Force; Use-Server B; Initialize-Vms -Source 'Test'; Set-VmsSimNetworkCut $true; Close-Vms }
}
if ($Shot) {
    foreach ($g in $guis.Values) { $g.WaitForExit(90000) | Out-Null }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    'screenshots saved'
} else {
    'Demo running: two VM Switcher windows (this PC plays both servers). Close the windows, then press Enter here to stop the watchdogs.'
    [void](Read-Host)
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

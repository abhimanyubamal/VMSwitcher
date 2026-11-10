#requires -Version 5.1
<#
  Builds dist\VMSwitcher-Setup-<version>.exe
    powershell -ExecutionPolicy Bypass -File build\build.ps1 [-Version 1.0.0] [-SkipInstaller]
  Needs only what ships with Windows (csc.exe from .NET Framework 4.x) plus Inno Setup 6 for the last step.
  No downloads: SQLite comes from Windows itself (winsqlite3.dll).
#>
param([string]$Version = '1.0.0', [switch]$SkipInstaller)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Stage = Join-Path $Root 'build\stage'
$Obj = Join-Path $Root 'build\obj'
$Csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
function Step([string]$t) { Write-Host "==> $t" -ForegroundColor Cyan }

Step 'Clean'
foreach ($d in $Stage, $Obj) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } ; New-Item -ItemType Directory $d | Out-Null }
New-Item -ItemType Directory -Force (Join-Path $Stage 'app\lib'), (Join-Path $Stage 'setup'), (Join-Path $Stage 'docs'), (Join-Path $Root 'assets'), (Join-Path $Root 'dist') | Out-Null

Step 'Draw the icon (computer with a green status light)'
Add-Type -AssemblyName System.Drawing
function New-IconBitmap([int]$S) {
    $b = New-Object System.Drawing.Bitmap $S, $S
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
    $f = $S / 64.0
    function RR($x, $y, $w, $h, $r) {
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc($x, $y, $r, $r, 180, 90); $p.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
        $p.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90); $p.AddArc($x, $y + $h - $r, $r, $r, 90, 90); $p.CloseFigure(); return $p
    }
    $slate = [System.Drawing.ColorTranslator]::FromHtml('#475569')
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#1F2937'))), (RR (2 * $f) (6 * $f) (56 * $f) (38 * $f) (8 * $f)))
    $g.DrawPath((New-Object System.Drawing.Pen $slate, ([math]::Max(1, 3 * $f))), (RR (2 * $f) (6 * $f) (56 * $f) (38 * $f) (8 * $f)))
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#0F3D24'))), 7 * $f, 11 * $f, 46 * $f, 28 * $f)
    $g.FillPolygon((New-Object System.Drawing.SolidBrush $slate), [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF (26 * $f), (44 * $f)), (New-Object System.Drawing.PointF (34 * $f), (44 * $f)), (New-Object System.Drawing.PointF (37 * $f), (52 * $f)), (New-Object System.Drawing.PointF (23 * $f), (52 * $f))))
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#64748B'))), (RR (14 * $f) (51 * $f) (32 * $f) (6 * $f) (5 * $f)))
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#0B1220'))), 36 * $f, 30 * $f, 28 * $f, 28 * $f)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#22C55E'))), 40 * $f, 34 * $f, 20 * $f, 20 * $f)
    $g.Dispose(); return $b
}
# Multi-size .ico with PNG frames (supported since Windows Vista).
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) { $ms = New-Object IO.MemoryStream; $bmp = New-IconBitmap $s; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); , $ms.ToArray() }
$ico = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
$IconPath = Join-Path $Root 'assets\vmswitcher.ico'
[IO.File]::WriteAllBytes($IconPath, $ico.ToArray())
$preview = New-IconBitmap 256; $preview.Save((Join-Path $Root 'assets\vmswitcher-256.png'), [System.Drawing.Imaging.ImageFormat]::Png); $preview.Dispose()

Step 'Compile with the in-box C# compiler'
if (-not (Test-Path $Csc)) { throw "csc.exe not found at $Csc" }
function Invoke-Csc([string[]]$CscArgs) {
    $out = & $Csc /nologo /optimize+ @CscArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $out | Write-Host; throw "csc failed: $($CscArgs -join ' ')" }
}
$native = Join-Path $Root 'src\native'
$manifest = Join-Path $native 'admin.manifest'
Invoke-Csc @('/target:library', "/out:$Stage\app\lib\VMSwitcher.Native.dll", '/r:System.Data.dll', '/r:System.Xml.dll', (Join-Path $Root 'src\lib\VmsSqlite.cs'))
Invoke-Csc @('/target:winexe', '/platform:anycpu', "/out:$Stage\VMSwitcher.exe", "/win32icon:$IconPath", "/win32manifest:$manifest", '/r:System.Windows.Forms.dll', (Join-Path $native 'Launcher.cs'))
Invoke-Csc @('/target:exe', '/platform:anycpu', '/define:TERMINAL', "/out:$Stage\VMSwitcherTerminal.exe", "/win32icon:$IconPath", "/win32manifest:$manifest", (Join-Path $native 'Launcher.cs'))
Invoke-Csc @('/target:exe', '/platform:anycpu', "/out:$Stage\VMSwitcherService.exe", "/win32icon:$IconPath", '/r:System.ServiceProcess.dll', (Join-Path $native 'WatchdogService.cs'))

Step 'Stage scripts, docs, config'
$src = Join-Path $Root 'src'
foreach ($f in 'VMSwitcher.Core.psm1', 'Watchdog.ps1', 'PeerServer.ps1', 'Terminal.ps1', 'Gui.ps1', 'Gui.xaml', 'Gui.Card.xaml') {
    # UTF-8 with BOM: PowerShell 5.1 then reads every character correctly.
    $text = [IO.File]::ReadAllText((Join-Path $src $f))
    [IO.File]::WriteAllText((Join-Path $Stage "app\$f"), $text, (New-Object Text.UTF8Encoding($true)))
}
Copy-Item (Join-Path $src 'lib\VmsSqlite.cs') (Join-Path $Stage 'app\lib\')
Copy-Item (Join-Path $Root 'config\config.default.json') (Join-Path $Stage 'app\')
Copy-Item $IconPath (Join-Path $Stage 'app\')
Copy-Item (Join-Path $Root 'setup\*.ps1') (Join-Path $Stage 'setup\')
Copy-Item (Join-Path $Root 'docs\Operator-Guide.html'), (Join-Path $Root 'docs\Live-Test-Sheet.md') (Join-Path $Stage 'docs\')

Step 'Check: the compiled SQLite DLL works'
$check = & powershell -NoProfile -Command "[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes('$Stage\app\lib\VMSwitcher.Native.dll')); [VMSwitcher.SqliteDb]::EngineVersion"
Write-Host "    winsqlite3 engine $check"

if ($SkipInstaller) { Write-Host 'Staged (installer skipped).' -ForegroundColor Green; return }

Step 'Build the installer with Inno Setup'
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found. Install it from https://jrsoftware.org/isdl.php and run this again.' }
& $iscc /Q "/DAppVer=$Version" (Join-Path $Root 'installer\VMSwitcher.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
$setup = Join-Path $Root "dist\VMSwitcher-Setup-$Version.exe"
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash
Set-Content -Path "$setup.sha256" -Value "$hash  VMSwitcher-Setup-$Version.exe" -Encoding ASCII
Write-Host ("Built {0} ({1:N1} MB)  SHA256 {2}" -f $setup, ((Get-Item $setup).Length / 1MB), $hash) -ForegroundColor Green

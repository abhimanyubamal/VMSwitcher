#requires -Version 5.1
# Peer endpoint for VM Switcher: lets the copy on the other server ask about this server's VM
# and ask this server to start / stop / restart it. Dot-sourced by Watchdog.ps1.
# TCP listener + tiny HTTP parser (no http.sys URL reservation needed); every request is
# handled in its own runspace so a slow Save-VM never blocks status queries.

function Start-VmsPeerServer {
    param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][int]$Port)
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $iss.ImportPSModule(@($ModulePath))
    $pool = [runspacefactory]::CreateRunspacePool(1, 6, $iss, $Host)
    $pool.Open()
    $sync = [hashtable]::Synchronized(@{ Stop = $false; Listening = $false; Error = ''; Requests = 0 })

    $handler = {
        param($Client)
        Initialize-Vms -Source 'Peer'
        try { Invoke-VmsPeerConnection $Client } finally { Close-Vms }
    }

    $acceptLoop = {
        param($Port, $Sync, $Pool, $Handler)
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        try { $listener.Start(); $Sync.Listening = $true }
        catch { $Sync.Error = $_.Exception.Message; return }
        $jobs = New-Object System.Collections.ArrayList
        try {
            while (-not $Sync.Stop) {
                for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
                    $j = $jobs[$i]
                    if ($j.Handle.IsCompleted) { try { [void]$j.PS.EndInvoke($j.Handle) } catch { } ; $j.PS.Dispose(); $jobs.RemoveAt($i) }
                }
                if ($listener.Pending()) {
                    $client = $listener.AcceptTcpClient()
                    $Sync.Requests++
                    $ps = [powershell]::Create()
                    $ps.RunspacePool = $Pool
                    [void]$ps.AddScript($Handler).AddArgument($client)
                    [void]$jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
                } else { Start-Sleep -Milliseconds 25 }
            }
        } finally { $listener.Stop() }
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($acceptLoop).AddArgument($Port).AddArgument($sync).AddArgument($pool).AddArgument($handler)
    $handle = $ps.BeginInvoke()
    # Give the listener a moment to bind, so a port problem is reported straight away.
    for ($i = 0; $i -lt 40 -and -not $sync.Listening -and -not $sync.Error; $i++) { Start-Sleep -Milliseconds 50 }
    return [pscustomobject]@{ Sync = $sync; PS = $ps; Handle = $handle; Runspace = $rs; Pool = $pool; Port = $Port }
}

function Stop-VmsPeerServer($Server) {
    if (-not $Server) { return }
    $Server.Sync.Stop = $true
    try { [void]$Server.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
    try { $Server.PS.Dispose(); $Server.Runspace.Close(); $Server.Pool.Close() } catch { }
}

<<<<<<< HEAD
# VMSwitcher
VM Switcher is Windows Service used to monitor two Hyper-V manager VMs and turn the backup VM 'ON' if the primary VM fails and then turn the secondary OFF automatically when the Primary VM gets back ON. It also has a GUI and a terminal UI with which you can control its other features.
=======
# VM Switcher 2.4

Active/standby failover for two Hyper-V virtual machines that run on **two different Windows Server 2016 hosts**.

| Server | VM | Role |
|---|---|---|
| 10.10.140.160 | `VirtuoSIS_16.0.0_IICC` | Primary |
| 10.10.140.140 | `VirtuoSIS_16.0.0_IICC_STANDBY` | Secondary |

VM Switcher is installed on **both** servers. Each copy:

- controls only **its own** server's Hyper-V (start, save, stop, restart of its local VM);
- reads its VM's health from the **Hyper-V heartbeat** integration service;
- talks to the copy on the other server every 3 seconds over TCP 47160, with HMAC-SHA256 signing and a shared key typed into both installers, and pings that server once (`ping -n 1` equivalent);
- shows both VMs in the windowed app (`VMSwitcher.exe`) and the numbered terminal (`VMSwitcherTerminal.exe`). Buttons act on whichever server holds the VM.

```
 10.10.140.160 (Primary VM)                      10.10.140.140 (Secondary VM)
 VMSwitcherWatchdog service  <-- TCP 47160 -->   VMSwitcherWatchdog service
 local Hyper-V only            HMAC + key        local Hyper-V only
```

## Rules

| Situation | What happens |
|---|---|
| Primary VM OFF/saved/critical, not stopped through VM Switcher | Secondary turned ON on the next check (about 3 to 6 s) |
| Primary VM running but heartbeat lost for 3 checks | Same failover (about 9 s) |
| Primary's server silent: no ping **and** no VM Switcher for 3 checks | Secondary's server turns the Secondary ON (about 9 to 12 s) |
| Primary's server pings but its VM Switcher is silent | Warning only, no failover (the Primary may be fine) |
| Contact returns and both VMs are ON | "BOTH VMs are ON" alert, then failback after 2 min |
| Primary starts again after a failover | **Safe failback**: the booting Primary is held PAUSED within about 1-3 s (nothing lost; measured 0.6-1.1 s in tests), the Secondary shuts down CLEANLY (data saved), then the Primary resumes. The shared IP address is never used twice. |
| Both VMs ON at any time (they share one IP address) | Same safe failback; a long-running Primary is not paused |
| Secondary does not finish its clean shutdown in 300 s (`ShutdownTimeoutSeconds`) | Hyper-V powers it off (last resort, Windows inside is hung) |
| Primary frozen (heartbeat lost) | Primary powered OFF first, then Secondary started |
| Server rebooted less than 5 min ago, Primary still OFF | Waits for Hyper-V auto-start |
| Maintenance mode (option 5) | Set on both servers; watch and log only |

Both watchdogs may decide. The server that holds a VM always performs the action under its own lock, and repeated requests are harmless no-ops.
Hand-off history is kept on the Secondary's server; the app shows it on both.
Alerts **never** bring the window to the front or un-minimize it. They flash the taskbar button and show a tray pop-up.

## Menu options

1 Turn ON Primary (becomes *Restart Primary* when frozen) · 2 Turn ON Secondary (only while the Primary is OFF) · 3 Turn OFF Secondary (clean shutdown, only if Primary healthy) · 4 Planned stop of Primary (clean shutdown; optional switchover: Primary fully OFF, then Secondary ON) · 5 Pause/resume auto-failover · 6 Event log (both servers merged) · 7 Hand-off history · 8 Failover dry run · 9 Open VM console · 0 Exit

## Layout

```
src/VMSwitcher.Core.psm1   config, roles, SQLite, providers, heartbeat health, peer client/protocol, failover brain, actions
src/Watchdog.ps1           3-second loop (run by the service), starts the peer endpoint
src/PeerServer.ps1         TCP listener for the other server (one runspace per request)
src/Terminal.ps1           console menu
src/Gui.ps1, Gui*.xaml     WPF app + tray notifier + demo "fire drill" panel
src/lib/VmsSqlite.cs       wrapper over Windows' built-in winsqlite3.dll
src/native/*.cs            launchers and service host (in-box csc.exe)
setup/install.ps1          config + DPAPI key, firewall, service, logon task, self-test
installer/VMSwitcher.iss   Inno Setup script
build/build.ps1            builds dist/VMSwitcher-Setup-<ver>.exe
tests/                     Pester: single-server, two-server decisions, live two-process test
```

## Build and test

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Version 2.4.0
powershell -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester tests"
```

Two-server demo on one PC (two watchdogs and two windows, simulated VMs):

```powershell
powershell -ExecutionPolicy Bypass -File tests\Start-TwoServerDemo.ps1
```

Unattended install, run on each server with the same key:
`VMSwitcher-Setup-2.4.0.exe /VERYSILENT /ROLE=PRIMARY /SHAREDKEY=...` on 10.10.140.160 and `/ROLE=SECONDARY` on 10.10.140.140 (`/ROLE=DEMO` for a training PC).

The installer's first page asks **Which server is this?** and pre-selects the answer from the machine's own IP address.
>>>>>>> bef5e4d ( VM Switching service for Windows for Hyper-V Manager VMs)

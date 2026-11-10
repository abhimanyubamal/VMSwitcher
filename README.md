# VMSwitcher

VM Switcher is a Windows service that monitors two Hyper-V VMs. It turns the backup (Secondary) VM ON if the Primary VM fails, and turns the Secondary OFF automatically, and safely, when the Primary comes back ON. It also has a windowed app (GUI) and a terminal menu for its other features.

The two VMs run on **two different Hyper-V servers** (Windows Server 2016 or newer). VM Switcher is installed on **both** servers, and the two copies talk to each other. There are **no built-in VM names or IP addresses**: you type them in the installer (see [Choose your own Primary and Secondary](#choose-your-own-primary-and-secondary)).

| Role | What you enter |
|---|---|
| Primary (normally serves users) | the Primary VM's name in Hyper-V Manager, and the IP address of the server it runs on |
| Secondary (backup) | the Secondary VM's name, and the IP address of its server |

The automatic failover and failback run in the **VM Switcher Watchdog** Windows service. They keep working when the app and the terminal are closed, and when nobody is signed in.

---

## 1. Using it from the terminal

Open **VM Switcher Terminal** from the Start menu or the desktop. It asks for administrator rights, because controlling Hyper-V needs them. You can also run `C:\Program Files\VMSwitcher\VMSwitcherTerminal.exe` directly.

The top of the screen refreshes every 3 seconds. It shows which server you are on, whether the other server is connected, and a status light for each VM.

```
  VM SWITCHER   HV-SERVER-2 holds the SECONDARY                   14:02:11
  Other server 192.168.1.10: connected
  PRIMARY    ██ HEALTH STATUS: OK          MyApp-Main
  SECONDARY  ░░ HEALTH STATUS: OFF         MyApp-Backup
   1  Turn ON Primary
   2  Turn ON Secondary
   3  Turn OFF Secondary
   ...
   0  Exit
```

Press a number to run an option. Options that are not allowed right now are greyed out, with the reason next to them. If the watchdog service has stopped, the screen says **press W to start it**.

| Key | Option | What it does |
|---|---|---|
| 1 | Turn ON Primary | Starts the Primary. If the Secondary is ON, it is shut down **cleanly first**, because both VMs use the same IP address. When the Primary is frozen, this option becomes *Restart Primary*. |
| 2 | Turn ON Secondary | Allowed only while the Primary is OFF. |
| 3 | Turn OFF Secondary | Clean shutdown of the Secondary. Allowed only while the Primary is healthy. |
| 4 | Planned stop of Primary | Clean shutdown with no failover alarm. It can switch users to the Secondary: the Primary is turned fully OFF first, then the Secondary is turned ON. |
| 5 | Pause / resume auto-failover | Maintenance mode on **both** servers: the watchdog only watches and logs. |
| 6 | What happened | Plain-English history from both servers. |
| 7 | VM hand-off history | Every failover and failback, with the gap in seconds. |
| 8 | Failover test (dry run) | Explains what would happen right now. Changes nothing. |
| 9 | Open VM console | Shows the screen of either VM. |
| 0 | Exit | Closes the terminal. Protection keeps running. |

**One option without the menu, for scripts and scheduled tasks.** The exit code is `0` when the option succeeds and `1` when it is refused or fails.

```powershell
VMSwitcherTerminal.exe 8                  # failover test
VMSwitcherTerminal.exe 3 -Yes             # turn OFF the Secondary, no question asked
VMSwitcherTerminal.exe 4 -Yes -Switchover # planned switch to the Secondary
VMSwitcherTerminal.exe 9 -Vm Secondary    # open the Secondary's screen
```

---

## 2. Installing and using the windowed app (GUI)

### Install (on both servers)

1. Copy `dist\VMSwitcher-Setup-<version>.exe` to **both** Hyper-V servers.
2. On the **Secondary's** server, run it as an administrator:
   - **Page 1, "Which server is this?"**: choose SECONDARY server. (On a re-run, the installer pre-selects it from the machine's own IP address.)
   - **Page 2**: type the Primary and Secondary VM names (exactly as in Hyper-V Manager) and the IP addresses of their two servers. There are no defaults. They must be **the same on both servers**. (On a re-run, page 2 shows the values from the server's current settings. Settings left by an old 1.x version are ignored, so the page starts empty.)
   - **Page 3**: a **shared key** of at least 12 characters. It proves to each server that the other one is genuine.
3. On the **Primary's** server, run the installer again with the **same values and the same key**.
4. After each install, a **self-test report** opens. Every line should say `OK`. On the second server it should also say "the shared keys match". Fix any `FAIL` line before going live.
5. On the Primary's server, give Hyper-V 60 seconds before it auto-starts the Primary after a reboot. VM Switcher is then already running and can keep the two VMs from using the shared IP address together:

   ```powershell
   Set-VM -Name '<Primary VM name>' -AutomaticStartDelay 60
   ```

The installer opens TCP port 47160 and ping in the Windows Firewall, **only for the other server**. Any other firewall between the servers must allow these too.

Unattended install, for example:

```powershell
VMSwitcher-Setup-<version>.exe /VERYSILENT /ROLE=SECONDARY /SHAREDKEY="..." /PRIMARYNAME="..." /PRIMARYIP=... /SECONDARYNAME="..." /SECONDARYIP=...
```

Use `/ROLE=PRIMARY` on the other server, or `/ROLE=DEMO` for a training PC. All four VM switches are required; without them an unattended install stops (unless the server already has them from an earlier install).

### Use

Open **VM Switcher** from the desktop. It also starts in the system tray (bottom-right corner) when an administrator signs in.

- **Two computer cards, one per VM**, each with a status light:
  - **Green:** OK.
  - **Yellow:** suspended or paused. During a failback, yellow means VM Switcher is holding the Primary on purpose.
  - **Grey:** error. A grey card with a **?** means the other server cannot be reached.
  - **Dark:** OFF. This is the normal state of the Secondary.
  - **Blinking:** the VM is busy starting or stopping.
- **One-sentence banner:** says what is going on and, when something is wrong, which button to press.
- **Pills at the top:** the state of the other server, the watchdog, and auto-failover. If the watchdog pill is red, click it to restart the service.
- **Nine numbered buttons:** the same options as the terminal. You can also press 1-9 on the keyboard. A greyed button says in yellow why it cannot be used right now.
- **Tabs at the bottom:** *What happened*, *VM hand-offs*, *Actions by people* (every click, with the Windows user name), and *Light changes*.
- **Alerts never jump in front of your work.** A tray pop-up appears, the taskbar button flashes, and a red strip waits in the window until you click **Got it**.
- **Closing the window keeps VM Switcher in the tray.** Protection never depends on the window.

**Training PC (no real VMs):** choose **Training PC** on page 1 of the installer. A purple *fire drill* panel then lets you crash the Primary, freeze it, or cut the network, and watch exactly what would happen. Nothing real is touched.

---

## 3. How to get the best out of it

- **Leave it alone.** On a normal day the Primary is green and the Secondary is dark (OFF). Failover and failback are automatic.
- **Before planned work on the Primary**, use option **4**, not Hyper-V Manager. There is no false alarm, and users can be moved to the Secondary.
- **For longer maintenance**, use option **5** (pause auto-failover), and press **5** again afterwards. The pill shows **PAUSED** in amber as a reminder.
- **Press 8 now and then.** The dry run is a free health check.
- **Read *What happened* after any incident.** It is written in plain English and covers both servers.
- **Keep the Hyper-V Heartbeat service enabled** in both VMs (VM Settings > Integration Services). VM Switcher reads VM health from it.
- **Keep the servers' clocks in sync** (Windows Time). A difference of more than 5 minutes makes the servers refuse each other.
- **Logs**, if you need them: `C:\ProgramData\VMSwitcher\logs\` and Event Viewer > Windows Logs > Application > source `VMSwitcher`.

### What happens, and when

| Situation | What VM Switcher does |
|---|---|
| Primary turned OFF or crashed (not through VM Switcher) | Secondary turned ON at the next check (about 3 s) |
| Primary frozen: heartbeat lost for 3 checks | Frozen Primary powered off, then Secondary turned ON |
| Primary's whole server silent (no ping, no VM Switcher) for 3 checks | Secondary's server turns the Secondary ON (about 9-12 s) |
| Primary's server pings but its VM Switcher does not answer | Warning only, no failover |
| Primary starts again after a failover | **Safe failback**: the booting Primary is held PAUSED within about 1-3 s (nothing is lost), the Secondary shuts down **cleanly** (its data is saved), then the Primary continues. The two VMs never use the shared IP address at the same time. |
| Both VMs found ON together | Same safe failback |
| Secondary does not finish shutting down within 300 s | Hyper-V powers it off. This is the last resort: Windows inside it is hung. |
| Server rebooted less than 5 minutes ago and Primary still OFF | Waits for Hyper-V to auto-start the Primary |

---

## Choose your own Primary and Secondary

Every part of VM Switcher reads the VM names and server IPs from its settings, so any pair of VMs on any two servers can be protected. Nothing is built in.

**The easy way:** run the installer again on **both** servers. Page 2 shows the current values (only when the settings file has both VM names and both server IPs; otherwise the page is empty). Change them, leave the shared key empty to keep it (or type a new one on both), and finish. Settings such as timings are kept.

**By hand:** edit `C:\ProgramData\VMSwitcher\config.json` on **both** servers. The two files must contain the same values.

```json
"Primary":   { "Name": "MyApp_MAIN",   "Host": "192.168.50.11" },
"Secondary": { "Name": "MyApp_BACKUP", "Host": "192.168.50.12" },
```

Then restart the service on both servers:

```powershell
Restart-Service VMSwitcherWatchdog
```

Re-run the installer as well if a server's IP address changed. The firewall rules allow only the other server's address.

Other settings in the same file:

| Setting | Default | Meaning |
|---|---|---|
| `CheckIntervalSeconds` | 3 | Normal check interval |
| `FastCheckIntervalSeconds` | 1 | Check interval while a failover or failback is active |
| `MissedPingsForFailover` | 3 | Missed checks before failing over |
| `ShutdownTimeoutSeconds` | 300 | Time for a clean shutdown before the last-resort power-off |
| `HostBootGraceSeconds` | 300 | Wait after a server reboot before any failover |
| `ListenPort` / `PeerPort` | 47160 | Port used between the two copies |

---

## For developers

```
src/VMSwitcher.Core.psm1   settings, roles, SQLite, Hyper-V and simulated providers, health, peer protocol, failover logic, actions
src/Watchdog.ps1           the check loop (run by the service), starts the peer endpoint
src/PeerServer.ps1         TCP endpoint for the other server
src/Terminal.ps1           terminal menu
src/Gui.ps1, Gui*.xaml     windowed app, tray notifier, fire-drill panel
src/lib/VmsSqlite.cs       wrapper over Windows' built-in winsqlite3.dll
src/native/*.cs            launchers and service host (built with the in-box csc.exe)
setup/install.ps1          settings, encrypted key, firewall, service, tray task, self-test
installer/VMSwitcher.iss   Inno Setup script
build/build.ps1            builds dist/VMSwitcher-Setup-<version>.exe
tests/                     Pester tests, including a live two-server test
docs/                      operator guide and live test sheet
```

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Version 2.5.2          # needs Inno Setup 6
powershell -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester tests"
powershell -ExecutionPolicy Bypass -File tests\Start-TwoServerDemo.ps1           # two servers simulated on one PC
```

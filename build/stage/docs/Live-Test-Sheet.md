# VM Switcher: live test on the two Hyper-V servers

Run this once after installing on both servers. Allow about 30 minutes, and plan a short service window for sections C to F.
Tick each box. Every step is also recorded in VM Switcher's "What happened" tab on both servers.

| Server | Runs VM | Role |
|---|---|---|
| _(Primary server IP)_ | _(Primary VM name)_ | PRIMARY |
| _(Secondary server IP)_ | _(Secondary VM name)_ | SECONDARY |

Fill in this table first. Below, **.P** means the Primary's server and **.S** the Secondary's server.

## A. Install (both servers)

- [ ] On **.S**, run `VMSwitcher-Setup-<version>.exe` as an administrator. Page 1: choose **SECONDARY server**. Page 2: type both VM names and both server IPs. Page 3: type a shared key.
- [ ] Its self-test says "This server holds the SECONDARY". A `WARN` that the other server is not answering is expected, because it is not installed there yet.
- [ ] On **.P**, install with the **same values and the same key**. Page 1: choose **PRIMARY server**. Its self-test says "This server holds the PRIMARY" and "the shared keys match".
- [ ] Open VM Switcher on each server. The header reads "This server: ... holds the PRIMARY" (or SECONDARY), and the pill shows **Other server ...: connected**.
- [ ] Both cards show the right lights within 3 seconds: Primary green, Secondary dark (OFF, ready to take over).

## B. Safe checks (nothing changes)

- [ ] On either server, press **8 Failover test**. It explains the crash, freeze, and server-death cases.
- [ ] Minimize the window. It must stay minimized for the rest of the test. Alerts only flash the taskbar button and show a tray pop-up.

## C. Primary VM crash (with VM Switcher CLOSED)

0. [ ] On both servers, close the VM Switcher window (tray: right-click > Close the app) and the terminal, or sign out. Protection must keep working: it runs in the **VM Switcher Watchdog** service.

1. [ ] In Hyper-V Manager on **.P**, right-click the Primary VM and choose **Turn Off**. Note the time.
2. [ ] Within about 3 to 6 seconds, both servers show a red strip, **Failover: Primary is down**, and the Secondary turns green within about 10 seconds.
3. [ ] **VM hand-offs** tab on either server shows one row with the gap in seconds.
4. [ ] In Hyper-V Manager on **.P**, start the Primary (as Hyper-V auto-start would). Within about 1-3 s its light turns YELLOW (held paused) and the banner says "Switching back to the Primary". The Secondary shuts down cleanly (blinking dark, then OFF), then the Primary continues booting. Note the time the clean shutdown took.
5. [ ] Crash the Primary again, wait for the failover, then press **1** on **.S**: the Secondary shuts down cleanly first, then the Primary starts.
6. [ ] During steps 4 and 5, run `ping <shared IP> -t` on a client. Afterwards, check both VMs' System event log: there must be no "duplicate IP address" error (Event ID 4199) on either VM. Note how long the Secondary needed to boot in step 2: that boot time is the failover gap.

## D. Whole Primary server lost (the important one)

1. [ ] Unplug the network cable of **.P**, or power it off.
2. [ ] On **.S**, the pill turns **UNREACHABLE** and the Primary card shows **?**. After about 9 to 12 seconds, the Secondary turns ON.
3. [ ] Reconnect **.P**. If its Primary kept running, the Secondary is shut down cleanly within seconds of contact coming back (alert: **Switching back to the Primary**, then **Back to the Primary**).

## E. VM Switcher stopped on one server

- [ ] On **.P**, stop the **VM Switcher Watchdog** service. On **.S**, a warning appears: "VM Switcher on (Primary server IP) is not answering". No failover happens, because the server still answers ping. Start the service again.

## F. Planned maintenance (from either server)

- [ ] Press **4 Planned stop of Primary**, then **Yes** to move users. The Primary shuts down cleanly and is fully OFF first, then the Secondary turns ON (shared IP address). **No** failover alarm appears.
- [ ] Press **1**. The Secondary is shut down cleanly first, then the Primary starts.
- [ ] Press **5** on one server. The pill says **PAUSED on both servers**. Press **5** again to resume.

## Report back

From both servers, send `C:\ProgramData\VMSwitcher\selftest.txt` and the day's `C:\ProgramData\VMSwitcher\logs\VMSwitcher-YYYY-MM-DD.log`.

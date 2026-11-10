// VMSwitcherService.exe: the Windows service "VMSwitcherWatchdog".
// It keeps app\Watchdog.ps1 running: starts it, restarts it if it ever exits (with back-off),
// and asks it to stop cleanly (named event) when the service stops.
// C# 5 so it builds with the csc.exe that ships inside Windows.
using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading;

public class WatchdogService : ServiceBase
{
    public const string Name = "VMSwitcherWatchdog";
    const string StopEventName = @"Global\VMSwitcherWatchdogStop";

    Process _child;
    Thread _monitor;
    volatile bool _stopping;
    EventWaitHandle _stopEvent;
    readonly ManualResetEvent _wake = new ManualResetEvent(false);

    public WatchdogService()
    {
        ServiceName = Name;
        CanStop = true;
        CanShutdown = true;
        AutoLog = true;
    }

    static EventWaitHandle CreateStopEvent()
    {
        var sec = new EventWaitHandleSecurity();
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            sec.AddAccessRule(new EventWaitHandleAccessRule(new SecurityIdentifier(sid, null), EventWaitHandleRights.FullControl, AccessControlType.Allow));
        // Anyone signed in may WAIT on the stop signal (harmless); only SYSTEM and Administrators may set it.
        sec.AddAccessRule(new EventWaitHandleAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), EventWaitHandleRights.Synchronize, AccessControlType.Allow));
        bool created;
        return new EventWaitHandle(false, EventResetMode.ManualReset, StopEventName, out created, sec);
    }

    protected override void OnStart(string[] args)
    {
        _stopping = false;
        _stopEvent = CreateStopEvent();
        _stopEvent.Reset();
        _monitor = new Thread(Loop) { IsBackground = true, Name = "watchdog-monitor" };
        _monitor.Start();
    }

    Process StartChild()
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(baseDir, @"app\Watchdog.ps1");
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = baseDir;
        return Process.Start(psi);
    }

    void Loop()
    {
        int delayMs = 2000;
        while (!_stopping)
        {
            DateTime started = DateTime.Now;
            int code = -1;
            try
            {
                _child = StartChild();
                _child.WaitForExit();
                code = _child.ExitCode;
            }
            catch (Exception ex)
            {
                Log("Could not start the VM Switcher watchdog script: " + ex.Message, EventLogEntryType.Error);
            }
            if (_stopping) break;
            // Quick crashes back off up to 1 minute; a long healthy run resets the delay.
            delayMs = (DateTime.Now - started).TotalMinutes > 5 ? 2000 : Math.Min(delayMs * 2, 60000);
            Log("The VM Switcher watchdog script stopped unexpectedly (exit code " + code + "). Restarting it in " + (delayMs / 1000) + " s.", EventLogEntryType.Warning);
            _wake.WaitOne(delayMs);
        }
    }

    protected override void OnStop()
    {
        _stopping = true;
        try { RequestAdditionalTime(20000); } catch (InvalidOperationException) { }   // not running under the service manager (/console)
        try { if (_stopEvent != null) _stopEvent.Set(); } catch { }
        _wake.Set();
        try
        {
            if (_child != null && !_child.HasExited && !_child.WaitForExit(15000)) _child.Kill();
        }
        catch { }
    }

    protected override void OnShutdown() { OnStop(); }

    void Log(string message, EventLogEntryType type)
    {
        try { EventLog.WriteEntry(message, type); } catch { }
    }

    static void Main(string[] args)
    {
        if (args.Length > 0 && args[0].Equals("/console", StringComparison.OrdinalIgnoreCase))
        {
            // Debug helper: run in the foreground, press Enter to stop.
            var s = new WatchdogService();
            s.OnStart(args);
            Console.WriteLine("VM Switcher watchdog running. Press Enter to stop.");
            Console.ReadLine();
            s.OnStop();
            return;
        }
        ServiceBase.Run(new WatchdogService());
    }
}

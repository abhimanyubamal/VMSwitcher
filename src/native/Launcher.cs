// VMSwitcher.exe (GUI, compiled with /target:winexe) and VMSwitcherTerminal.exe (compiled with /define:TERMINAL).
// Tiny launchers so operators double-click a real program with an icon. Both request administrator rights
// through their manifest, because controlling Hyper-V needs them.
// C# 5 so it builds with the csc.exe that ships inside Windows.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
#if TERMINAL
        string script = Path.Combine(baseDir, @"app\Terminal.ps1");
        string sta = "";
#else
        string script = Path.Combine(baseDir, @"app\Gui.ps1");
        string sta = "-STA ";
#endif
        if (!File.Exists(script))
        {
            Fail("VM Switcher is damaged: " + script + " is missing. Please reinstall.");
            return 2;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");

        var extra = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
#if TERMINAL
            // "VMSwitcherTerminal.exe 3" means "run option 3".
            int n;
            if (i == 0 && int.TryParse(a, out n)) { extra.Append("-Option ").Append(n).Append(' '); continue; }
#endif
            extra.Append(Quote(a)).Append(' ');
        }

        var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass " + sta + "-File " + Quote(script) + " " + extra.ToString());
        psi.UseShellExecute = false;
        psi.WorkingDirectory = baseDir;
#if !TERMINAL
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
#endif
        try
        {
            Process p = Process.Start(psi);
#if TERMINAL
            p.WaitForExit();
            return p.ExitCode;
#else
            return 0;
#endif
        }
        catch (Exception ex)
        {
            Fail("Could not start VM Switcher: " + ex.Message);
            return 3;
        }
    }

    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    static void Fail(string message)
    {
#if TERMINAL
        Console.Error.WriteLine(message);
#else
        System.Windows.Forms.MessageBox.Show(message, "VM Switcher", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
#endif
    }
}

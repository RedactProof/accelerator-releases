// RedactProof Accelerator - Windows system tray
//
// Mirrors installer/macos/menu_bar.swift (the reference spec): status,
// Open RedactProof, Restart Bridge, View Log, Check for Updates, Uninstall,
// Quit, version display.
//
// Compiled by build.ps1 (and CI) with the .NET Framework 4.x csc.exe that
// ships in Windows itself - no new toolchain. That compiler only speaks
// C# 5, so no string interpolation, null-conditionals, or expression-bodied
// members in this file.
//
// Launch/ownership model:
//  - HKCU\Run, the scheduled task action, and the installer's final launch
//    all start THIS exe. On startup it ensures the bridge is running by
//    delegating to LaunchAccelerator.exe --direct (single place that knows
//    how to spawn node hidden - do NOT duplicate that logic here, and do
//    NOT reintroduce wscript/hidden powershell: that pattern is what
//    Defender ML flagged as Trojan:Win32/Commando.A!ml in <=0.1.2).
//  - Single instance via a named mutex. A second instance (e.g. the
//    scheduled task fired from a redactproof:// link while the tray is
//    already up) checks bridge health, revives it if it is down, and exits.
//  - The bridge is deliberately NOT a child process: it must survive tray
//    Quit-vs-crash asymmetries and browser Job Objects. We find it via
//    bridge.pid / a path-filtered process scan, same as the installer.

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    const string MutexName = "RedactProofAcceleratorTray";

    [STAThread]
    static void Main()
    {
        bool createdNew;
        Mutex mutex = new Mutex(true, MutexName, out createdNew);
        if (!createdNew)
        {
            // Another tray owns the icon. Still honour the launch intent:
            // if the bridge is down, revive it, then get out of the way.
            if (!Bridge.IsHealthy(2000)) Bridge.StartDirect();
            return;
        }
        try
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }
}

static class Bridge
{
    public static string InstallDir
    {
        get { return Path.GetDirectoryName(Application.ExecutablePath); }
    }

    static string RedactproofDir
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".redactproof"); }
    }

    public static string LogPath
    {
        get { return Path.Combine(RedactproofDir, "bridge.log"); }
    }

    // Port from ~/.redactproof/accelerator.json. Parsed with a regex rather
    // than a JSON library to keep the exe dependency-free; the file is
    // machine-written by server.mjs so the shape is stable.
    public static int Port()
    {
        try
        {
            string cfg = Path.Combine(RedactproofDir, "accelerator.json");
            if (File.Exists(cfg))
            {
                Match m = Regex.Match(File.ReadAllText(cfg), "\"port\"\\s*:\\s*(\\d+)");
                if (m.Success) return int.Parse(m.Groups[1].Value);
            }
        }
        catch { }
        return 47821;
    }

    public static bool IsHealthy(int timeoutMs)
    {
        try
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(
                "http://127.0.0.1:" + Port() + "/health");
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            {
                return resp.StatusCode == HttpStatusCode.OK;
            }
        }
        catch
        {
            return false;
        }
    }

    public static void StartDirect()
    {
        try
        {
            string stub = Path.Combine(InstallDir, "LaunchAccelerator.exe");
            if (!File.Exists(stub)) return;
            ProcessStartInfo psi = new ProcessStartInfo(stub, "--direct");
            psi.UseShellExecute = false;
            psi.WorkingDirectory = InstallDir;
            using (Process p = Process.Start(psi)) { }
        }
        catch { }
    }

    // Same two layers the installer uses: the recorded pid, then a
    // path-filtered sweep so a stale pid file can't leave a zombie holding
    // the port (and we never touch unrelated node.exe processes).
    public static void Stop()
    {
        string nodePath = Path.Combine(InstallDir, "node.exe");
        try
        {
            string pidFile = Path.Combine(InstallDir, "bridge.pid");
            if (File.Exists(pidFile))
            {
                int pid;
                if (int.TryParse(File.ReadAllText(pidFile).Trim(), out pid))
                {
                    try
                    {
                        Process p = Process.GetProcessById(pid);
                        if (IsOurNode(p, nodePath)) { p.Kill(); p.WaitForExit(3000); }
                    }
                    catch { }
                }
            }
        }
        catch { }
        try
        {
            foreach (Process p in Process.GetProcessesByName("node"))
            {
                try { if (IsOurNode(p, nodePath)) { p.Kill(); p.WaitForExit(3000); } }
                catch { }
            }
        }
        catch { }
    }

    static bool IsOurNode(Process p, string nodePath)
    {
        try
        {
            return string.Equals(p.MainModule.FileName, nodePath, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

class TrayContext : ApplicationContext
{
    const string AppUrl = "https://app.redactproof.com";
    const string ReleasesUrl = "https://github.com/RedactProof/accelerator-releases/releases";

    NotifyIcon icon;
    ToolStripMenuItem statusItem;
    ToolStripMenuItem versionItem;
    System.Threading.Timer healthTimer;
    volatile bool connected;
    bool lastShown = true; // force first UpdateUi to render

    public TrayContext()
    {
        icon = new NotifyIcon();
        icon.Icon = LoadAppIcon();
        icon.Visible = true;
        icon.ContextMenuStrip = BuildMenu();

        if (!Bridge.IsHealthy(2000)) Bridge.StartDirect();

        // Poll off the UI thread (sync HTTP would freeze the menu), marshal
        // the result back. 3s cadence matches the macOS menu bar.
        healthTimer = new System.Threading.Timer(delegate(object _)
        {
            bool ok = Bridge.IsHealthy(2000);
            connected = ok;
            try
            {
                if (icon.ContextMenuStrip.IsHandleCreated)
                    icon.ContextMenuStrip.BeginInvoke(new MethodInvoker(UpdateUi));
                else
                    UpdateUi();
            }
            catch { }
        }, null, 0, 3000);
    }

    Icon LoadAppIcon()
    {
        try
        {
            string ico = Path.Combine(Bridge.InstallDir, "app.ico");
            if (File.Exists(ico)) return new Icon(ico);
        }
        catch { }
        return SystemIcons.Application;
    }

    ContextMenuStrip BuildMenu()
    {
        ContextMenuStrip menu = new ContextMenuStrip();

        statusItem = new ToolStripMenuItem("○ Not connected");
        statusItem.Enabled = false;
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add("Open RedactProof", null, delegate(object s, EventArgs e) { OpenUrl(AppUrl); });
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add("Restart Bridge", null, delegate(object s, EventArgs e) { RestartBridge(); });
        menu.Items.Add("View Log", null, delegate(object s, EventArgs e) { ViewLog(); });
        menu.Items.Add("Check for Updates", null, delegate(object s, EventArgs e) { OpenUrl(ReleasesUrl); });
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add("Uninstall…", null, delegate(object s, EventArgs e) { ConfirmUninstall(); });
        menu.Items.Add("Quit", null, delegate(object s, EventArgs e) { Quit(); });
        menu.Items.Add(new ToolStripSeparator());

        versionItem = new ToolStripMenuItem("Accelerator v" + Application.ProductVersion);
        versionItem.Enabled = false;
        menu.Items.Add(versionItem);

        return menu;
    }

    void UpdateUi()
    {
        if (connected == lastShown) return;
        lastShown = connected;
        statusItem.Text = connected ? "● Connected" : "○ Not connected";
        // NotifyIcon.Text caps at 63 chars - keep it short.
        icon.Text = connected
            ? "RedactProof Accelerator - Connected"
            : "RedactProof Accelerator - Not connected";
    }

    void RestartBridge()
    {
        connected = false;
        UpdateUi();
        Bridge.Stop();
        Thread.Sleep(750);
        Bridge.StartDirect();
    }

    void ViewLog()
    {
        try
        {
            if (!File.Exists(Bridge.LogPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Bridge.LogPath));
                File.WriteAllText(Bridge.LogPath, "");
            }
            ProcessStartInfo psi = new ProcessStartInfo("notepad.exe", "\"" + Bridge.LogPath + "\"");
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        catch { }
    }

    void OpenUrl(string url)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(url);
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        catch { }
    }

    void ConfirmUninstall()
    {
        DialogResult r = MessageBox.Show(
            "This will stop the Accelerator and remove it from your PC. Your RedactProof account and documents are not affected.",
            "Uninstall RedactProof Accelerator?",
            MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
        if (r != DialogResult.OK) return;
        try
        {
            string un = Path.Combine(Bridge.InstallDir, "Uninstall.exe");
            if (File.Exists(un))
            {
                ProcessStartInfo psi = new ProcessStartInfo(un);
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
        }
        catch { }
        ExitTray(false); // uninstaller stops the bridge itself
    }

    void Quit()
    {
        // Per the launch-UX spec, Quit stops the helper, not just the icon
        // (matches macOS applicationWillTerminate killing the server).
        ExitTray(true);
    }

    void ExitTray(bool stopBridge)
    {
        try { healthTimer.Dispose(); } catch { }
        if (stopBridge) Bridge.Stop();
        icon.Visible = false;
        icon.Dispose();
        Application.Exit();
    }
}

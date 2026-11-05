// BUSHWAR Foreman — installer.
// One exe a builder runs: clones/updates the app into a hidden per-user app dir,
// creates Start Menu + Desktop shortcuts and an Add/Remove Programs entry, then
// offers to launch. The install IS a git clone, so the app keeps self-updating
// on every launch. Run with /uninstall to remove everything.
// Built by tools\build-exe.ps1 (csc.exe ships with Windows).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

static class Setup
{
    const string RepoUrl = "https://github.com/chazman69/bushwar-foreman-app.git";   // public mirror: no invite needed
    const string AppName = "BUSHWAR Foreman";
    const string RegKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\BushwarForeman";

    static string InstallDir
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\BushwarForeman"); }
    }

    [STAThread]
    static void Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0].Equals("/uninstall", StringComparison.OrdinalIgnoreCase))
                Uninstall();
            else
                Install();
        }
        catch (Exception ex)
        {
            MessageBox.Show("Setup failed: " + RootMessage(ex), AppName + " Setup");
        }
    }

    // Reflection/COM calls (CreateShortcut's InvokeMember) wrap the real failure in a
    // TargetInvocationException whose own Message is the useless "Exception has been
    // thrown by the target of an invocation" — dig down to the innermost message.
    static string RootMessage(Exception ex)
    {
        while (ex.InnerException != null) ex = ex.InnerException;
        return ex.Message;
    }

    static string FindGit()
    {
        // Git for Windows on PATH / default location
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string g = Path.Combine(pf, @"Git\cmd\git.exe");
        if (File.Exists(g)) return g;
        foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try { string c = Path.Combine(dir.Trim(), "git.exe"); if (File.Exists(c)) return c; } catch { }
        }
        // GitHub Desktop's bundled git (what the builders have)
        string desktop = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GitHubDesktop");
        if (Directory.Exists(desktop))
        {
            string[] apps = Directory.GetDirectories(desktop, "app-*");
            Array.Sort(apps);
            Array.Reverse(apps);
            foreach (string a in apps)
            {
                string c = Path.Combine(a, @"resources\app\git\cmd\git.exe");
                if (File.Exists(c)) return c;
            }
        }
        return null;
    }

    // Wire up Git Credential Manager explicitly for the auth operations (clone/pull).
    // GitHub Desktop's bundled git — what most builders have — doesn't configure a
    // credential helper for external command-line use, so a plain clone of a PRIVATE
    // repo finds no credentials, has no terminal to prompt on, and dies with GitHub's
    // generic "repository not found" 404. Naming the helper here makes GCM pop its own
    // sign-in window (browser OAuth) when there are no stored credentials — turning a
    // dead-end into an actual login. The empty first value clears any inherited helper
    // so we never prompt twice; guiPrompt=true forces the GUI over any TTY helper.
    static string CredHelperArgs(string git)
    {
        string helper = "manager";
        try
        {
            string root = Path.GetDirectoryName(Path.GetDirectoryName(git)); // ...\Git  or  ...\resources\app\git
            string[] dirs = { @"mingw64\bin", @"mingw64\libexec\git-core" };
            bool modern = false, core = false;
            foreach (string d in dirs)
            {
                if (File.Exists(Path.Combine(root, d, "git-credential-manager.exe"))) modern = true;
                if (File.Exists(Path.Combine(root, d, "git-credential-manager-core.exe"))) core = true;
            }
            if (!modern && core) helper = "manager-core"; // older Git for Windows / GitHub Desktop bundles
        }
        catch { }
        return "-c credential.helper= -c credential.helper=" + helper + " -c credential.guiPrompt=true ";
    }

    static int RunGit(string git, string arguments, out string stderr)
    {
        var psi = new ProcessStartInfo
        {
            FileName = git,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            // GIT_TERMINAL_PROMPT=0 disables git-core's own TTY prompt so a headless run
            // can never HANG waiting on a console that doesn't exist. It does NOT gag the
            // credential helper: Git Credential Manager (named via CredHelperArgs) shows
            // its own GUI/browser sign-in independently, so a missing credential now pops
            // a real login instead of failing instantly. If auth still fails, git's real
            // stderr comes straight back for the error dialog.
            EnvironmentVariables = { { "GIT_TERMINAL_PROMPT", "0" } }
        };
        using (var p = Process.Start(psi))
        {
            string err = p.StandardError.ReadToEnd();
            p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            stderr = err.Trim();
            return p.ExitCode;
        }
    }

    static void Install()
    {
        string git = FindGit();
        if (git == null)
        {
            MessageBox.Show("Couldn't find git on this machine.\n\nInstall GitHub Desktop first (desktop.github.com), sign in, then run this setup again.", AppName + " Setup");
            return;
        }

        string dir = InstallDir;
        int code;
        string stderr;
        if (Directory.Exists(Path.Combine(dir, ".git")))
        {
            code = RunGit(git, CredHelperArgs(git) + "-C \"" + dir + "\" pull --ff-only", out stderr);
            if (code != 0)
            {
                MessageBox.Show("Couldn't update the existing install. Check your internet / GitHub sign-in and try again.\n\nGit said:\n" + (stderr.Length > 0 ? stderr : "(no output — exit code " + code + ")"), AppName + " Setup");
                return;
            }
        }
        else
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            Directory.CreateDirectory(Path.GetDirectoryName(dir));
            // Public repo, so no sign-in is needed (GCM may still pop one; signing in is harmless).
            code = RunGit(git, CredHelperArgs(git) + "clone \"" + RepoUrl + "\" \"" + dir + "\"", out stderr);
            if (code != 0)
            {
                MessageBox.Show("Couldn't download " + AppName + ".\n\nMake sure:\n  1. You're online and github.com opens in your browser.\n  2. GitHub Desktop is installed (it brings git with it).\n\nThen run setup again.\n\nGit said:\n" + (stderr.Length > 0 ? stderr : "(no output — exit code " + code + ")"), AppName + " Setup");
                return;
            }
        }

        string exe = Path.Combine(dir, "FOREMAN.exe");
        if (!File.Exists(exe)) { MessageBox.Show("Downloaded, but FOREMAN.exe is missing. Ask in the group chat.", AppName + " Setup"); return; }

        // keep a copy of setup inside the install for Add/Remove Programs
        string selfCopy = Path.Combine(dir, "Setup.exe");
        try { File.Copy(Assembly.GetExecutingAssembly().Location, selfCopy, true); } catch { selfCopy = Assembly.GetExecutingAssembly().Location; }

        // shortcuts: Desktop + Start Menu — this is all the user ever sees. Best-effort:
        // WScript.Shell can fail (COM blocked by policy/AV; OneDrive-redirected Desktops
        // have rejected the .lnk save in the field), and by this point the app is fully
        // installed and launchable — a missing shortcut must never abort the install.
        string deskWarn = TryCreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), AppName + ".lnk"), exe, dir, "Desktop");
        string startMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), AppName + ".lnk");
        string menuWarn = TryCreateShortcut(startMenu, exe, dir, "Start Menu");
        string warnings = deskWarn + menuWarn;

        // Add/Remove Programs entry
        using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RegKey))
        {
            k.SetValue("DisplayName", AppName);
            k.SetValue("DisplayIcon", exe);
            k.SetValue("DisplayVersion", "0.3");
            k.SetValue("Publisher", "BUSHWAR");
            k.SetValue("InstallLocation", dir);
            k.SetValue("UninstallString", "\"" + selfCopy + "\" /uninstall");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }

        string where;
        if (deskWarn.Length == 0 && menuWarn.Length == 0) where = "You'll find it in your Start Menu and on your Desktop.";
        else if (deskWarn.Length == 0) where = "You'll find it on your Desktop.";
        else if (menuWarn.Length == 0) where = "You'll find it in your Start Menu.";
        else where = "You can start it any time from:\n" + exe;
        if (MessageBox.Show(AppName + " is installed.\n\n" + where + warnings + "\n\nLaunch it now?", AppName + " Setup", MessageBoxButtons.YesNo) == DialogResult.Yes)
            Process.Start(new ProcessStartInfo { FileName = exe, WorkingDirectory = dir, UseShellExecute = true });
    }

    static void Uninstall()
    {
        if (MessageBox.Show("Remove " + AppName + " from this machine?\n(Your map repo and your work are NOT touched.)", AppName + " Setup", MessageBoxButtons.YesNo) != DialogResult.Yes)
            return;
        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), AppName + ".lnk"));
        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), AppName + ".lnk"));
        try { Registry.CurrentUser.DeleteSubKeyTree(RegKey, false); } catch { }
        try { Directory.Delete(InstallDir, true); } catch { }
        string cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BushwarForeman");
        try { Directory.Delete(cfg, true); } catch { }
        MessageBox.Show(AppName + " removed.", AppName + " Setup");
    }

    static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }

    // Returns "" on success, or a warning paragraph to append to the done dialog.
    static string TryCreateShortcut(string lnkPath, string target, string workDir, string label)
    {
        try { CreateShortcut(lnkPath, target, workDir); return ""; }
        catch (Exception ex)
        {
            return "\n\n(Couldn't create the " + label + " shortcut: " + RootMessage(ex) + "\nThe app itself installed fine.)";
        }
    }

    // Known field failures (Malvia, OneDrive-redirected Desktop): the COM Save() call
    // can be denied by Defender's Controlled Folder Access (unsigned exe writing a .lnk
    // to a protected Desktop) or trip over OneDrive sync locks; some machines disable
    // Windows Script Host entirely. All of these surface here as exceptions — callers
    // go through TryCreateShortcut so none of them can kill the install.
    static void CreateShortcut(string lnkPath, string target, string workDir)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        if (t == null) throw new Exception("Windows Script Host is disabled on this machine.");
        object shell = Activator.CreateInstance(t);
        object lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
        Type lt = lnk.GetType();
        lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
        lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { workDir });
        lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { "BUSHWAR Foreman - map team collaboration" });
        lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
    }
}

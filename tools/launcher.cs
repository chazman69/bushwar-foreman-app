// BUSHWAR Foreman — native launcher.
// A tiny WinExe that starts the PowerShell app hidden, so Foreman looks and
// behaves like a normal desktop program (real .exe, BW icon, no console).
// Built by tools\build-exe.ps1 using the csc.exe that ships with Windows.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, @"src\foreman.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show(
                "Couldn't find src\\foreman.ps1 next to FOREMAN.exe.\n\n" +
                "Run FOREMAN.exe from inside the bushwar-foreman folder (or a shortcut to it).",
                "BUSHWAR Foreman");
            return;
        }
        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" + script + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = root
        };
        try { Process.Start(psi); }
        catch (Exception ex)
        {
            MessageBox.Show("Failed to start Foreman: " + ex.Message, "BUSHWAR Foreman");
        }
    }
}

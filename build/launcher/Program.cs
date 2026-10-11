// GatewayLens.exe - starts GatewayLens.ps1 in PowerShell 7.
//
// The script travels inside this exe. On each start it is written to
// %LOCALAPPDATA%\GatewayLens\app\<version>\GatewayLens.ps1 (only when it differs
// from what is already there) and run with:
//     pwsh -NoProfile -ExecutionPolicy Bypass -STA -File <script> -Launched <your arguments>
// -Launched tells the script there is no console, so it shows problems in a
// message box. -SelfTest, -Inspect and -DeviceCode keep the console visible,
// because they write to it.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace GatewayLens.Launcher
{
    internal static class Program
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_ICONERROR = 0x10;
        private const string Title = "GatewayLens";

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string script = ExtractScript();
                string pwsh = FindPwsh();
                if (pwsh == null)
                {
                    MessageBoxW(IntPtr.Zero,
                        "GatewayLens needs PowerShell 7.\r\n\r\n" +
                        "Install it with:\r\n    winget install Microsoft.PowerShell\r\n\r\n" +
                        "then start GatewayLens again.",
                        Title, MB_ICONERROR);
                    return 1;
                }

                bool needsConsole = args.Any(a =>
                    a.Equals("-SelfTest", StringComparison.OrdinalIgnoreCase) ||
                    a.Equals("-Inspect", StringComparison.OrdinalIgnoreCase) ||
                    a.Equals("-DeviceCode", StringComparison.OrdinalIgnoreCase));

                var all = new List<string> { "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", script, "-Launched" };
                if (needsConsole) all.Insert(0, "-NoExit");
                all.AddRange(args);

                var psi = new ProcessStartInfo(pwsh, string.Join(" ", all.Select(Quote)))
                {
                    UseShellExecute = false,
                    CreateNoWindow = !needsConsole
                };
                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBoxW(IntPtr.Zero, "GatewayLens could not start:\r\n\r\n" + ex.Message, Title, MB_ICONERROR);
                return 1;
            }
        }

        private static string ExtractScript()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            byte[] bytes;
            using (Stream s = asm.GetManifestResourceStream("GatewayLens.ps1"))
            {
                if (s == null) throw new InvalidOperationException("This build does not contain the script.");
                using (var ms = new MemoryStream())
                {
                    s.CopyTo(ms);
                    bytes = ms.ToArray();
                }
            }
            string version = asm.GetName().Version.ToString();
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "GatewayLens", "app", version);
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, "GatewayLens.ps1");
            if (!File.Exists(path) || !File.ReadAllBytes(path).SequenceEqual(bytes))
            {
                File.WriteAllBytes(path, bytes);
            }
            return path;
        }

        private static string FindPwsh()
        {
            var candidates = new List<string>();
            foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            {
                string d = dir.Trim().Trim('"');
                if (d.Length == 0) continue;
                try { candidates.Add(Path.Combine(d, "pwsh.exe")); }
                catch (ArgumentException) { }     // a PATH entry with invalid characters
            }
            // ProgramW6432 is the 64-bit Program Files even if this ever runs as 32-bit
            foreach (string pf in new[] {
                         Environment.GetEnvironmentVariable("ProgramW6432"),
                         Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) })
            {
                if (string.IsNullOrEmpty(pf)) continue;
                candidates.Add(Path.Combine(pf, "PowerShell", "7", "pwsh.exe"));
                candidates.Add(Path.Combine(pf, "PowerShell", "7-preview", "pwsh.exe"));
            }
            candidates.Add(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Microsoft", "WindowsApps", "pwsh.exe"));
            return candidates.FirstOrDefault(File.Exists);
        }

        // Quote one argument so the Windows command line reads it back unchanged.
        internal static string Quote(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
            var sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in a)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { sb.Append('\\', slashes * 2 + 1); sb.Append('"'); }
                else { sb.Append('\\', slashes); sb.Append(c); }
                slashes = 0;
            }
            sb.Append('\\', slashes * 2);
            sb.Append('"');
            return sb.ToString();
        }
    }
}

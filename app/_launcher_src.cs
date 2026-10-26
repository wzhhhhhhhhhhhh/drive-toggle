using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class Program
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr ShellExecute(IntPtr hwnd, string lpOperation, string lpFile,
        string lpParameters, string lpDirectory, int nShowCmd);

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string here = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            string mode = args.Length == 0 ? "setup" : args[0].ToLowerInvariant();

            // 1) 初始化（双击无参数即进入）：提权后由本程序去拉 setup.ps1
            if (mode == "setup")
            {
                IntPtr r = ShellExecute(IntPtr.Zero, "runas", System.Reflection.Assembly.GetExecutingAssembly().Location,
                    "--elevated-setup", here, 0);
                if ((long)r <= 32)
                {
                    Msg("无法启动初始化（可能取消了 UAC）。");
                    return 3;
                }
                return 0;
            }

            if (mode == "--elevated-setup")
            {
                RunPowerShell(here, ResolveScript(here, "setup.ps1"), "", true);
                return 0;
            }

            // 2) 触发计划任务（静默）
            if (mode == "task" && args.Length > 1)
            {
                var psi = new ProcessStartInfo("schtasks.exe", "/run /tn \"" + args[1] + "\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.WorkingDirectory = here;
                Process.Start(psi);
                return 0;
            }

            // 3) 由计划任务调用：无窗口地跑某个 ps1（不会闪控制台）
            if (mode == "run" && args.Length > 1)
            {
                var sb = new StringBuilder();
                for (int i = 2; i < args.Length; i++)
                {
                    if (sb.Length > 0) sb.Append(' ');
                    sb.Append(args[i]);
                }
                RunPowerShell(here, ResolveScript(here, args[1]), sb.ToString(), false);
                return 0;
            }

            return 1;
        }
        catch (Exception ex)
        {
            Msg(ex.Message);
            return 9;
        }
    }

    // 脚本既可能在 exe 同级，也可能在 app\ 子目录（仓库布局）
    static string ResolveScript(string here, string name)
    {
        string flat = Path.Combine(here, name);
        if (File.Exists(flat)) return flat;
        string inApp = Path.Combine(Path.Combine(here, "app"), name);
        if (File.Exists(inApp)) return inApp;
        return flat;   // 交给 RunPowerShell 报「找不到脚本」
    }

    static void LauncherLog(string msg)
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "drive-toggle");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "launcher.log"),
                DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg + Environment.NewLine);
        }
        catch { }
    }

    static void RunPowerShell(string workDir, string script, string extraArgs, bool wait)
    {
        LauncherLog("RunPowerShell workDir=" + workDir + " script=" + script + " args=" + extraArgs);
        if (!File.Exists(script)) { Msg("找不到脚本：" + script); return; }
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
        if (!string.IsNullOrEmpty(extraArgs)) arguments += " " + extraArgs;

        var psi = new ProcessStartInfo("powershell.exe", arguments);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = workDir;
        psi.WindowStyle = ProcessWindowStyle.Hidden;

        try
        {
            var p = Process.Start(psi);
            LauncherLog("started pid=" + (p == null ? -1 : p.Id));
            if (wait && p != null) p.WaitForExit();
        }
        catch (Exception ex) { LauncherLog("start failed: " + ex.Message); throw; }
    }

    static void Msg(string text)
    {
        try
        {
            string js = text.Replace("'", " ").Replace("\r", " ").Replace("\n", " ");
            ShellExecute(IntPtr.Zero, "open", "mshta.exe",
                "javascript:alert('" + js + "');close()", null, 0);
        }
        catch { }
    }
}

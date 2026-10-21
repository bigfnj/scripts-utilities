// Creates an owned hidden console solely to exercise actual console events.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
internal static class NativeShimConsoleProbe
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, xSize, ySize, xChars, yChars, fill, flags;
        public short show, reservedBytes;
        public IntPtr reservedData, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public IntPtr process, thread; public int processId, threadId; }
    private delegate bool Handler(uint kind);
    private static Handler active;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string application, StringBuilder command,
        IntPtr ps, IntPtr ts, bool inherit, uint flags, IntPtr environment,
        string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(Handler handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint kind, uint group);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll")] private static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    private static int Main(string[] args)
    {
        if (args[0] == "--wait")
        {
            string marker = args[1];
            active = delegate(uint kind) {
                if (kind > 1) return false;
                File.WriteAllText(marker + ".event", kind.ToString());
                Environment.Exit(73);
                return true;
            };
            if (!SetConsoleCtrlHandler(active, true)) return 92;
            File.WriteAllText(marker, "ready");
            // A failed controller never leaves an unbounded process behind.
            Thread.Sleep(12000);
            return 93;
        }
        ProcessInfo child = new ProcessInfo();
        try
        {
            string launcher = args[0], marker = args[1];
            uint kind = UInt32.Parse(args[2]);
            StartupInfo startup = new StartupInfo();
            startup.cb = Marshal.SizeOf(typeof(StartupInfo));
            startup.flags = 1; // STARTF_USESHOWWINDOW
            startup.show = 0; // SW_HIDE, no desktop application is presented.
            StringBuilder command = new StringBuilder("\"" + launcher + "\" --wait \"" + marker + "\"");
            if (!CreateProcessW(launcher, command, IntPtr.Zero, IntPtr.Zero, false, 0x10,
                IntPtr.Zero, null, ref startup, out child)) throw new Win32Exception(Marshal.GetLastWin32Error());
            for (int i = 0; i < 100 && !File.Exists(marker); ++i) Thread.Sleep(50);
            if (!File.Exists(marker)) return 94;
            FreeConsole();
            if (!AttachConsole((uint)child.processId)) throw new Win32Exception(Marshal.GetLastWin32Error());
            active = delegate(uint eventKind) { return true; };
            if (!SetConsoleCtrlHandler(active, true)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!GenerateConsoleCtrlEvent(kind, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (WaitForSingleObject(child.process, 5000) != 0) return 95;
            uint code;
            if (!GetExitCodeProcess(child.process, out code)) return 96;
            return code == 73 && File.ReadAllText(marker + ".event") == kind.ToString() ? 0 : 97;
        }
        catch (Exception error) { File.WriteAllText(args[1] + ".error", error.ToString()); return 98; }
        finally
        {
            FreeConsole();
            if (child.thread != IntPtr.Zero) CloseHandle(child.thread);
            if (child.process != IntPtr.Zero)
            {
                WaitForSingleObject(child.process, 13000);
                CloseHandle(child.process);
            }
        }
    }
}
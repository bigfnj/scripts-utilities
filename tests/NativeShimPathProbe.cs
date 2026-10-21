using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeShimPathProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetShortPathNameW(string longPath, StringBuilder shortPath, uint size);

    public static string ShortPath(string path)
    {
        StringBuilder buffer = new StringBuilder(32768);
        uint length = GetShortPathNameW(path, buffer, (uint)buffer.Capacity);
        if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length >= buffer.Capacity) throw new InvalidOperationException("Short path exceeds the test probe buffer.");
        return buffer.ToString();
    }
}
// EXE-backed toolbox wrappers must never send arguments through cmd.exe.
// Preserve the caller's complete raw command-line tail, including its quoting.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Serialization.Json;
using System.Text.RegularExpressions;
using System.Xml;
using System.Text;
using System.Web.Script.Serialization;

internal static class NativeShim
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
    private struct ProcessInfo
    {
        public IntPtr process, thread;
        public int processId, threadId;
    }
    private delegate bool ConsoleHandler(uint kind);
    private static readonly ConsoleHandler Handler = delegate(uint kind) { return kind == 0 || kind == 1; };
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetCommandLineW();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string application, StringBuilder commandLine,
        IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags,
        IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleHandler handler, bool add);

    private static string Tail(string raw)
    {
        // argv[0] has the Windows executable-name rule: quotes toggle grouping;
        // backslashes are literal here. Do not apply the later-argument grammar.
        int i = 0;
        bool quoted = false;
        for (; i < raw.Length; ++i)
        {
            char c = raw[i];
            if (c == '"') quoted = !quoted;
            else if (!quoted && (c == ' ' || c == '\t')) break;
        }
        if (quoted || i == 0) throw new InvalidDataException("Invalid launcher command line.");
        return raw.Substring(i);
    }
    private static Dictionary<string, object> Object(object value, int keys)
    {
        Dictionary<string, object> item = value as Dictionary<string, object>;
        if (item == null || item.Count != keys) throw new InvalidDataException("Invalid native shim metadata.");
        return item;
    }
    private static void RejectDuplicateFields(byte[] json)
    {
        Dictionary<int, HashSet<string>> scopes = new Dictionary<int, HashSet<string>>();
        using (XmlDictionaryReader reader = JsonReaderWriterFactory.CreateJsonReader(json, XmlDictionaryReaderQuotas.Max))
        {
            while (reader.Read())
            {
                if (reader.NodeType != XmlNodeType.Element) continue;
                int depth = reader.Depth;
                List<int> ended = new List<int>();
                foreach (int old in scopes.Keys) if (old >= depth) ended.Add(old);
                foreach (int old in ended) scopes.Remove(old);
                HashSet<string> parent;
                if (scopes.TryGetValue(depth - 1, out parent) && !parent.Add(reader.LocalName))
                    throw new InvalidDataException("Duplicate native shim metadata field.");
                if (reader.GetAttribute("type") == "object") scopes[depth] = new HashSet<string>(StringComparer.Ordinal);
            }
        }
    }
    private static string Expand(string value)
    {
        const string variable = "%[A-Za-z_][A-Za-z0-9_()]*%";
        if (Regex.Replace(value, variable, "").IndexOf('%') >= 0 || value.IndexOf('!') >= 0)
            throw new InvalidDataException("Unsupported CMD environment expansion.");
        string[] dynamic = { "CD", "DATE", "TIME", "RANDOM", "ERRORLEVEL", "CMDEXTVERSION",
            "CMDCMDLINE", "HIGHESTNUMANODENUMBER", "__APPDIR__", "__CD__" };
        return Regex.Replace(value, variable, delegate(Match match) {
            string name = match.Value.Substring(1, match.Length - 2);
            if (Array.IndexOf(dynamic, name.ToUpperInvariant()) >= 0)
                throw new InvalidDataException("CMD pseudo-variable expansion is unsupported.");
            return Environment.GetEnvironmentVariable(name) ?? "";
        });
    }
    private static bool Absolute(string value)
    {
        return value != null && value.Length > 3 &&
            ((Char.IsLetter(value[0]) && value[1] == ':' && value[2] == '\\') || value.StartsWith("\\\\", StringComparison.Ordinal));
    }
    private static int Main()
    {
        ProcessInfo process = new ProcessInfo();
        bool handlerAdded = false;
        try
        {
            string self = Path.GetFullPath(System.Reflection.Assembly.GetExecutingAssembly().Location);
            string metadata = Path.ChangeExtension(self, ".shim.json");
            if (new FileInfo(metadata).Length > 65536) throw new InvalidDataException("Native shim metadata is too large.");
            byte[] json = File.ReadAllBytes(metadata);
            RejectDuplicateFields(json);
            Dictionary<string, object> config = Object(new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(json)), 3);
            object version, targetValue, changes;
            if (!config.TryGetValue("schema_version", out version) || !(version is int) || (int)version != 1 ||
                !config.TryGetValue("target", out targetValue) || !config.TryGetValue("environment", out changes))
                throw new InvalidDataException("Invalid native shim metadata fields.");
            string target = targetValue as string;
            if (!Absolute(target) || target.IndexOfAny(new char[] { '\r', '\n', '\0', '"', '%' }) >= 0 ||
                !target.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Native shim target must be an absolute executable path.");
            target = Path.GetFullPath(target);
            if (String.Equals(target, self, StringComparison.OrdinalIgnoreCase) ||
                File.Exists(Path.ChangeExtension(target, ".shim.json")))
                throw new InvalidDataException("Native shim chains and self targets are refused.");
            if (!File.Exists(target)) throw new FileNotFoundException("Native shim target is missing.", target);
            object[] environment = changes as object[];
            if (environment == null || environment.Length > 32) throw new InvalidDataException("Invalid native shim environment.");
            foreach (object entry in environment)
            {
                Dictionary<string, object> item = Object(entry, 2);
                object nameValue, settingValue;
                if (!item.TryGetValue("name", out nameValue) || !item.TryGetValue("value", out settingValue))
                    throw new InvalidDataException("Invalid native shim environment fields.");
                string name = nameValue as string, setting = settingValue as string;
                if (String.IsNullOrEmpty(name) || setting == null ||
                    name.IndexOfAny(new char[] { '=', '\r', '\n', '\0', '%' }) >= 0 ||
                    setting.IndexOfAny(new char[] { '\r', '\n', '\0' }) >= 0)
                    throw new InvalidDataException("Invalid native shim environment assignment.");
                Environment.SetEnvironmentVariable(name, Expand(setting));
            }
            string tail = Tail(Marshal.PtrToStringUni(GetCommandLineW()));
            StringBuilder command = new StringBuilder("\"" + target + "\"" + tail);
            StartupInfo startup = new StartupInfo();
            startup.cb = Marshal.SizeOf(typeof(StartupInfo));
            startup.flags = 0x100; // STARTF_USESTDHANDLES, including redirected pipes/files.
            startup.input = GetStdHandle(-10);
            startup.output = GetStdHandle(-11);
            startup.error = GetStdHandle(-12);
            // A handler delegate, rather than the NULL/TRUE ignore flag: the latter
            // would make the child inherit ignored Ctrl-C. The child must receive it.
            handlerAdded = SetConsoleCtrlHandler(Handler, true);
            if (!CreateProcessW(target, command, IntPtr.Zero, IntPtr.Zero, true, 0,
                IntPtr.Zero, null, ref startup, out process)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (WaitForSingleObject(process.process, 0xFFFFFFFF) != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint code;
            if (!GetExitCodeProcess(process.process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)code);
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("native shim: " + error.Message);
            return 126;
        }
        finally
        {
            if (process.thread != IntPtr.Zero) CloseHandle(process.thread);
            if (process.process != IntPtr.Zero) CloseHandle(process.process);
            if (handlerAdded) SetConsoleCtrlHandler(Handler, false);
        }
    }
}
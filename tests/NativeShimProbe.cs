using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

internal static class NativeShimProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetCommandLineW();
    private static int Main(string[] args)
    {
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = new UTF8Encoding(false);
        Dictionary<string, object> result = new Dictionary<string, object>();
        result["args"] = args;
        result["raw"] = Marshal.PtrToStringUni(GetCommandLineW());
        result["stdin"] = Console.In.ReadToEnd();
        result["cwd"] = Environment.CurrentDirectory;
        result["fixture"] = Environment.GetEnvironmentVariable("SU_SHIM_FIXTURE");
        result["nested"] = Environment.GetEnvironmentVariable("SU_SHIM_NESTED");
        result["path"] = Environment.GetEnvironmentVariable("PATH");
        Console.WriteLine(new JavaScriptSerializer().Serialize(result));
        Console.Error.WriteLine("fixture stderr");
        return args.Length > 0 && args[0].StartsWith("--exit=", StringComparison.Ordinal) ? Int32.Parse(args[0].Substring(7)) : 0;
    }
}
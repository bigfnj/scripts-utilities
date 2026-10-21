// A DELETE lease prevents new readers from blocking a staged owned-pair removal.
// The publisher still validates paths and ownership before calling this helper.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace DevToolbox.NativeShimFilesTemplate
{
    public static class Files
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
            public System.Runtime.InteropServices.ComTypes.FILETIME Access;
            public System.Runtime.InteropServices.ComTypes.FILETIME Write;
            public uint Volume;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Links;
            public uint IndexHigh;
            public uint IndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access,
            uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle,
            out FileInformation information);

        public static string DirectoryIdentity(string path)
        {
            // Read directory identity without requesting data access. The same
            // volume/file index is returned through long names and 8.3 aliases.
            using (SafeFileHandle handle = CreateFileW(path, 0, 7, IntPtr.Zero,
                3, 0x02200000, IntPtr.Zero)) // OPEN_REPARSE_POINT | BACKUP_SEMANTICS
            {
                if (handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Cannot acquire native shim directory identity: " + path);
                FileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((information.Attributes & 0x10u) == 0 ||
                    (information.Attributes & 0x400u) != 0)
                    throw new IOException("Native shim identity requires an ordinary directory.");
                return information.Volume.ToString("X8") + ":" +
                    information.IndexHigh.ToString("X8") + information.IndexLow.ToString("X8");
            }
        }

        public static SafeFileHandle OpenDeleteLease(string path)
        {
            // GENERIC_READ | DELETE; FILE_SHARE_READ | FILE_SHARE_DELETE.
            // Hold DELETE access so a later reader must also allow deletion.
            // Refuse write sharing while the leased bytes are being removed.
            SafeFileHandle handle = CreateFileW(path, 0x80010000, 5, IntPtr.Zero,
                3, 0x00200000, IntPtr.Zero); // OPEN_EXISTING, OPEN_REPARSE_POINT
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Cannot acquire native companion delete lease: " + path);
            }
            try
            {
                FileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((information.Attributes & (0x10u | 0x400u)) != 0)
                    throw new IOException("Native companion lease requires an ordinary file.");
                return handle;
            }
            catch { handle.Dispose(); throw; }
        }

        public static string Hash(SafeFileHandle handle)
        {
            // A non-owning wrapper lets FileStream dispose without releasing the lease.
            using (SafeFileHandle borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
            using (FileStream stream = new FileStream(borrowed, FileAccess.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                stream.Position = 0;
                return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "");
            }
        }
    }
}
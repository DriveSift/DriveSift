# 原生文件系统访问层：读取真实占用（含压缩/稀疏）、硬链接数、可跳过重解析点的遍历。
# 用 C# 而不是纯 PowerShell 循环，是为了在大目录（十万级文件）下保持可用的速度。
if (-not ('DriveSift.Native' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace DriveSift
{
    public sealed class FileRecord
    {
        public string Path { get; set; }
        public long Length { get; set; }
        public long Allocated { get; set; }
        public DateTime LastWriteUtc { get; set; }
        public bool IsReparse { get; set; }
    }

    public static class Native
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public FILETIME CreationTime;
            public FILETIME LastAccessTime;
            public FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateFileW")]
        private static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(IntPtr hFile, out BY_HANDLE_FILE_INFORMATION lpInfo);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        // 返回文件在磁盘上真正占用的字节数；压缩与稀疏文件会小于 Length。
        public static long AllocatedSize(string path)
        {
            uint high = 0;
            uint low = GetCompressedFileSize(path, out high);
            if (low == 0xFFFFFFFF && high == 0xFFFFFFFF) return -1;
            return ((long)high << 32) + (long)low;
        }

        // 大于 1 说明该文件被多个路径共享，删除它不会释放全部空间。
        public static int LinkCount(string path)
        {
            IntPtr handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (handle == new IntPtr(-1)) return 1;
            try
            {
                BY_HANDLE_FILE_INFORMATION info;
                if (GetFileInformationByHandle(handle, out info)) return (int)info.NumberOfLinks;
                return 1;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        public static List<FileRecord> Walk(string root, bool skipReparse, int maxDepth, bool exactAllocation)
        {
            List<FileRecord> records = new List<FileRecord>();
            if (File.Exists(root))
            {
                try { records.Add(MakeRecord(root, exactAllocation)); } catch { }
                return records;
            }

            Stack<object[]> pending = new Stack<object[]>();
            pending.Push(new object[] { root, 0 });

            while (pending.Count > 0)
            {
                object[] item = pending.Pop();
                string dir = (string)item[0];
                int depth = (int)item[1];

                DirectoryInfo di = new DirectoryInfo(dir);
                if (!di.Exists) continue;

                try
                {
                    foreach (FileInfo file in di.EnumerateFiles())
                    {
                        try { records.Add(MakeRecord(file.FullName, exactAllocation)); } catch { }
                    }
                }
                catch { }

                if (maxDepth >= 0 && depth >= maxDepth) continue;

                try
                {
                    foreach (DirectoryInfo child in di.EnumerateDirectories())
                    {
                        try
                        {
                            FileAttributes attr = child.Attributes;
                            // 绝不穿越 junction / 符号链接，否则会删到别的盘去
                            if (skipReparse && (attr & FileAttributes.ReparsePoint) != 0) continue;
                            pending.Push(new object[] { child.FullName, depth + 1 });
                        }
                        catch { }
                    }
                }
                catch { }
            }
            return records;
        }

        private static FileRecord MakeRecord(string path, bool exactAllocation)
        {
            FileInfo info = new FileInfo(path);
            FileRecord record = new FileRecord();
            record.Path = path;
            record.Length = info.Length;
            record.IsReparse = (info.Attributes & FileAttributes.ReparsePoint) != 0;
            record.LastWriteUtc = info.LastWriteTimeUtc;
            if (exactAllocation)
            {
                long allocated = AllocatedSize(path);
                record.Allocated = allocated >= 0 ? allocated : info.Length;
            }
            else
            {
                record.Allocated = info.Length;
            }
            return record;
        }
    }
}
'@
}

function Invoke-DsWalk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$ExactAllocation,
        [int]$MaxDepth = -1
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        return [DriveSift.Native]::Walk($Path, $true, $MaxDepth, [bool]$ExactAllocation)
    }
    catch {
        Write-Warning "无法扫描 ${Path}: $($_.Exception.Message)"
        return @()
    }
}

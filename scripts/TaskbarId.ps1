<#
.SYNOPSIS
    Helpers that give each Claude profile its own taskbar button and pin.

.DESCRIPTION
    Windows groups taskbar buttons by AppUserModelID (AUMID). Every Claude
    instance carries the package's AUMID, so all profiles collapse into one
    button and cannot be pinned separately. Writing a per-profile AUMID onto
    both the profile's shortcut and the instance's windows makes the taskbar
    treat each profile as its own app.

    Dot-source this file; it defines the ClaudeProfiles.Taskbar type and the
    functions below. Used by Setup.ps1 (shortcut IDs) and Launch-Claude.ps1
    (window IDs).
#>

if (-not ('ClaudeProfiles.Taskbar' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace ClaudeProfiles {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
    }

    // Only the string (VT_LPWSTR) case is needed here.
    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant {
        public ushort vt;
        public ushort r1, r2, r3;
        public IntPtr p;
        public IntPtr p2;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PropertyKey k);
        [PreserveSig] int GetValue(ref PropertyKey k, out PropVariant v);
        [PreserveSig] int SetValue(ref PropertyKey k, ref PropVariant v);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile {
        [PreserveSig] int GetClassID(out Guid c);
        [PreserveSig] int IsDirty();
        [PreserveSig] int Load([MarshalAs(UnmanagedType.LPWStr)] string f, uint mode);
        [PreserveSig] int Save([MarshalAs(UnmanagedType.LPWStr)] string f, bool remember);
        [PreserveSig] int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
        [PreserveSig] int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }

    public static class Taskbar {
        static readonly Guid AppModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        static PropertyKey Id = new PropertyKey(AppModel, 5);
        static PropertyKey RelaunchCommand = new PropertyKey(AppModel, 2);
        static PropertyKey RelaunchIcon = new PropertyKey(AppModel, 3);
        static PropertyKey RelaunchName = new PropertyKey(AppModel, 4);

        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid riid, out IPropertyStore ps);
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);

        static PropVariant Str(string s) {
            var v = new PropVariant();
            v.vt = 31; // VT_LPWSTR
            v.p = Marshal.StringToCoTaskMemUni(s);
            return v;
        }

        static string Get(IPropertyStore ps, PropertyKey k) {
            PropVariant v;
            if (ps.GetValue(ref k, out v) != 0) return null;
            string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null;
            PropVariantClear(ref v);
            return s;
        }

        static void Set(IPropertyStore ps, PropertyKey k, string s) {
            var v = Str(s);
            try { Marshal.ThrowExceptionForHR(ps.SetValue(ref k, ref v)); }
            finally { PropVariantClear(ref v); }
        }

        static IPropertyStore WindowStore(IntPtr h) {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore ps;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(h, ref iid, out ps));
            return ps;
        }

        public static IntPtr[] WindowsOf(int[] pids) {
            var set = new HashSet<uint>();
            foreach (var p in pids) set.Add((uint)p);
            var found = new List<IntPtr>();
            EnumWindows((h, l) => {
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (set.Contains(pid)) found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        public static string GetWindowId(IntPtr h) {
            var ps = WindowStore(h);
            try { return Get(ps, Id); } finally { Marshal.ReleaseComObject(ps); }
        }

        // Relaunch properties go first: the taskbar reads them when the ID
        // changes, so "Pin to taskbar" on the running window keeps our launcher.
        public static void SetWindowId(IntPtr h, string id, string command, string name, string icon) {
            var ps = WindowStore(h);
            try {
                if (!string.IsNullOrEmpty(command)) {
                    Set(ps, RelaunchCommand, command);
                    Set(ps, RelaunchName, name);
                    if (!string.IsNullOrEmpty(icon)) Set(ps, RelaunchIcon, icon);
                }
                Set(ps, Id, id);
            } finally { Marshal.ReleaseComObject(ps); }
        }

        public static string GetShortcutId(string lnk) {
            var link = new ShellLink();
            try {
                Marshal.ThrowExceptionForHR(((IPersistFile)link).Load(lnk, 0));
                return Get((IPropertyStore)link, Id);
            } finally { Marshal.ReleaseComObject(link); }
        }

        public static void SetShortcutId(string lnk, string id) {
            var link = new ShellLink();
            try {
                var file = (IPersistFile)link;
                Marshal.ThrowExceptionForHR(file.Load(lnk, 2)); // STGM_READWRITE
                var ps = (IPropertyStore)link;
                Set(ps, Id, id);
                Marshal.ThrowExceptionForHR(ps.Commit());
                Marshal.ThrowExceptionForHR(file.Save(lnk, true));
            } finally { Marshal.ReleaseComObject(link); }
        }
    }
}
'@
}

# The default data folder keeps the app's own identity (and any existing
# Claude pin); every other profile gets "ClaudeProfiles.<folder name>".
function Get-ClaudeProfileAppId {
    param([string]$ProfileDir)
    $dir = $ProfileDir.TrimEnd('\')
    if ($dir -ieq (Join-Path $env:APPDATA 'Claude')) { return $null }
    'ClaudeProfiles.' + ((Split-Path $dir -Leaf) -replace '[^A-Za-z0-9]', '')
}

# The AUMID the installed app itself uses, e.g. "Claude_pzs8sxrjxfjjc!Claude".
function Get-ClaudePackageAppId {
    param($Package)
    $manifest = $Package | Get-AppxPackageManifest -ErrorAction SilentlyContinue
    $apps = @($manifest.Package.Applications.Application)
    $app = $apps | Where-Object { $_.Id -eq 'Claude' } | Select-Object -First 1
    if (-not $app) { $app = $apps | Select-Object -First 1 }
    if ($app) { "$($Package.PackageFamilyName)!$($app.Id)" }
}

# Main (browser) processes of the Claude instance started with $ProfileDir.
function Get-ClaudeInstancePids {
    param([string]$ProfileDir)
    $dir = $ProfileDir.TrimEnd('\')
    Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            # Only the desktop app; Claude Code's CLI is also named claude.exe.
            if ($_.ExecutablePath -notmatch '\\WindowsApps\\Claude_[^\\]+\\app\\Claude\.exe$') { return $false }
            $cl = $_.CommandLine
            if (-not $cl -or $cl -match '--type=') { return $false }
            $cl -match '--user-data-dir=(?:"([^"]+)"|(\S+))' -and
                ($Matches[1] + $Matches[2]).TrimEnd('\') -ieq $dir
        } |
        ForEach-Object { [int]$_.ProcessId }
}

# Keeps tagging the instance's windows with $AppId for as long as it runs,
# since the app can create new windows at any time. One watcher per profile.
function Watch-ClaudeWindows {
    param(
        [string]$ProfileDir,
        [string]$AppId,
        [string]$RelaunchCommand,
        [string]$DisplayName,
        [string]$IconResource
    )
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, "Local\$AppId.TaskbarWatcher", [ref]$created)
    if (-not $created) { return }

    $pids = @()
    $started = Get-Date
    try {
        while ($true) {
            $alive = @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            if ($alive.Count -eq 0) {
                $alive = @(Get-ClaudeInstancePids -ProfileDir $ProfileDir)
                # Give the app a minute to start before deciding it is gone.
                if ($alive.Count -eq 0 -and ((Get-Date) - $started).TotalSeconds -gt 60) { break }
            }
            $pids = $alive

            if ($pids.Count) {
                foreach ($h in [ClaudeProfiles.Taskbar]::WindowsOf([int[]]$pids)) {
                    try {
                        if ([ClaudeProfiles.Taskbar]::GetWindowId($h) -ne $AppId) {
                            [ClaudeProfiles.Taskbar]::SetWindowId($h, $AppId, $RelaunchCommand, $DisplayName, $IconResource)
                        }
                    } catch { }
                }
            }
            Start-Sleep -Milliseconds $(if (((Get-Date) - $started).TotalSeconds -lt 60) { 500 } else { 2000 })
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

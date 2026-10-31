<#
.SYNOPSIS
    Installs "clones" of the Claude Desktop app: one isolated profile + one
    desktop shortcut per account.

.DESCRIPTION
    For each profile name you pass, this script:
      * creates an isolated Chromium data directory under %APPDATA% (required so
        the Cowork VM works -- see the note in the loop below),
      * copies the launcher scripts into -InstallDir\bin (so the shortcuts keep
        working even if you delete this repo),
      * creates a "Claude (<Name>)" shortcut on your Desktop that opens the app
        with that profile, using the real Claude icon.

    The special profile name "Work" can reuse the account the normally-installed
    app is already signed into (-ReuseDefaultForWork), so you don't have to log
    in again for your main account.

.PARAMETER Profile
    One or more profile names. Default: Work, Personal.

.PARAMETER InstallDir
    Where the launcher scripts (bin\) live. Default: %USERPROFILE%\ClaudeProfiles.
    NOTE: profile *data* always lives under %APPDATA%\<name>, not here -- this is
    required for the Cowork VM to start (the native VM service resolves rootfs.vhdx
    under %APPDATA% regardless of --user-data-dir).

.PARAMETER ReuseDefaultForWork
    Make the "Work" profile reuse the existing %APPDATA%\Claude login instead of
    a fresh, separate one.

.PARAMETER ConfigDir
    Optional hashtable mapping a profile name to a Claude Code / Cowork config
    directory (CLAUDE_CONFIG_DIR). Use this to give a profile its own isolated
    memory + settings store, separate from any other account.

.PARAMETER NoProfileBadge
    Keep the plain Claude icon on isolated profiles' shortcuts. By default each
    one gets the Claude icon with a coloured badge showing the profile's initial,
    so separately pinned taskbar buttons are easy to tell apart.

.EXAMPLE
    .\Setup.ps1
    # Creates "Claude (Work)" and "Claude (Personal)" on the Desktop.

.EXAMPLE
    .\Setup.ps1 -Profile Personal,Side,Client -ReuseDefaultForWork

.EXAMPLE
    # Personal profile gets its own isolated Claude Code memory store:
    .\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal" }
#>
[CmdletBinding()]
param(
    [string[]]$Profile = @('Work', 'Personal'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [switch]$ReuseDefaultForWork,
    [hashtable]$ConfigDir = @{},
    [switch]$NoProfileBadge
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'TaskbarId.ps1')

# Draws the profile's initial in a coloured badge on top of the Claude icon, so
# separately pinned profiles can be told apart on the taskbar.
function New-ProfileIcon {
    param([string]$BaseIcoPath, [string]$IcoPath, [string]$Letter, [string]$Color)
    $base = $null; $bmp = $null; $g = $null
    try {
        # The base .ico is the single PNG frame Export-AppIcon wrote; read the
        # PNG directly (System.Drawing.Icon can't always decode PNG frames).
        $bytes = [System.IO.File]::ReadAllBytes($BaseIcoPath)
        $size = [BitConverter]::ToInt32($bytes, 14)
        $offset = [BitConverter]::ToInt32($bytes, 18)
        $base = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes[$offset..($offset + $size - 1)])))
        $bmp = New-Object System.Drawing.Bitmap 256, 256
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.DrawImage($base, 0, 0, 256, 256)

        # Bottom-right badge with a white ring so it reads on the orange icon.
        $d = 143; $x = 256 - $d; $ring = 10
        $g.FillEllipse([System.Drawing.Brushes]::White, $x, $x, $d, $d)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Color))
        $g.FillEllipse($brush, $x + $ring, $x + $ring, $d - 2 * $ring, $d - 2 * $ring)
        $brush.Dispose()
        $font = New-Object System.Drawing.Font 'Segoe UI', 74, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $g.DrawString($Letter, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF $x, ($x + 4), $d, $d), $fmt)
        $font.Dispose()

        Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
        return $true
    } catch {
        return $false
    } finally {
        if ($g) { $g.Dispose() }
        if ($bmp) { $bmp.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

# Extracts the highest-resolution icon out of an .exe into a standalone .ico.
# This is what makes shortcut icons survive app updates: the Claude .exe lives
# under C:\Program Files\WindowsApps\Claude_<version>__...\app\Claude.exe, and
# that <version> folder is DELETED whenever Claude auto-updates. A shortcut whose
# IconLocation points straight at that versioned path goes blank after the next
# update + icon-cache rebuild (typically noticed after a reboot). Copying the
# icon once to a stable file under bin\ and pointing every shortcut there avoids
# the dangling path entirely.
function Export-AppIcon {
    param([string]$ExePath, [string]$IcoPath, [int]$Size = 256)
    Add-Type -AssemblyName System.Drawing
    $sig = @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int PrivateExtractIcons(string lpszFile, int nIconIndex, int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, int flags);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr hIcon);
'@
    $api = Add-Type -MemberDefinition $sig -Name 'IconExtract' -Namespace 'Win32Native' -PassThru

    # Writes a 32-bit, full-colour, PNG-compressed .ico (Vista+ format) from a
    # Bitmap. We deliberately do NOT use Icon.Save(): saving an Icon created from
    # an HICON drops the colour plane and writes only the 1-bit AND mask, which is
    # why the icon came out grey. Rendering to a Bitmap and packing the PNG
    # ourselves preserves colour and alpha. Script-scoped so New-ProfileIcon can
    # reuse it.
    function script:Write-IcoFromBitmap {
        param([System.Drawing.Bitmap]$Bmp, [string]$Path)
        $ms = New-Object System.IO.MemoryStream
        $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $ms.ToArray(); $ms.Dispose()
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $bw = New-Object System.IO.BinaryWriter($fs)
        $bw.Write([uint16]0)            # reserved
        $bw.Write([uint16]1)            # type = icon
        $bw.Write([uint16]1)            # image count
        $dim = if ($Bmp.Width -ge 256) { 0 } else { [byte]$Bmp.Width }   # 0 means 256
        $bw.Write([byte]$dim)           # width
        $bw.Write([byte]$dim)           # height
        $bw.Write([byte]0)              # palette count
        $bw.Write([byte]0)              # reserved
        $bw.Write([uint16]1)            # colour planes
        $bw.Write([uint16]32)           # bits per pixel
        $bw.Write([uint32]$png.Length)  # image size
        $bw.Write([uint32]22)           # offset = 6 (dir) + 16 (entry)
        $bw.Write($png)
        $bw.Flush(); $bw.Close()
    }

    $h = New-Object IntPtr[] 1
    $id = New-Object int[] 1
    try {
        $n = $api::PrivateExtractIcons($ExePath, 0, $Size, $Size, $h, $id, 1, 0)
        if ($n -gt 0 -and $h[0] -ne [IntPtr]::Zero) {
            $ico = [System.Drawing.Icon]::FromHandle($h[0])
            $bmp = $ico.ToBitmap()       # full 32bpp colour + alpha
            Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
            $bmp.Dispose(); $ico.Dispose()
            return $true
        }
    } catch {
    } finally {
        if ($h[0] -ne [IntPtr]::Zero) { $api::DestroyIcon($h[0]) | Out-Null }
    }
    # Fallback: managed helper (lower-res, but still full colour and a stable file).
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        $bmp = $ico.ToBitmap()
        Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
        $bmp.Dispose(); $ico.Dispose()
        return $true
    } catch { return $false }
}

# --- Verify the Claude Desktop app is installed and find its icon ---------
$pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) {
    throw "Claude Desktop app not found. Install it from https://claude.ai/download (or the Microsoft Store) first."
}
$iconExe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
Write-Host "Found Claude $($pkg.Version) at $($pkg.InstallLocation)" -ForegroundColor Green

# --- Copy launcher scripts to a stable location ---------------------------
$binDir = Join-Path $InstallDir 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item (Join-Path $scriptRoot 'Launch-Claude.ps1') $binDir -Force
Copy-Item (Join-Path $scriptRoot 'launch.vbs') $binDir -Force
Copy-Item (Join-Path $scriptRoot 'TaskbarId.ps1') $binDir -Force
$vbs = Join-Path $binDir 'launch.vbs'

# --- Extract the Claude icon to a STABLE path (survives app updates) -------
# See Export-AppIcon above for why pointing IconLocation at the versioned
# WindowsApps .exe makes icons disappear after updates/reboots.
$icoPath = Join-Path $binDir 'claude.ico'
if (Export-AppIcon -ExePath $iconExe -IcoPath $icoPath) {
    $iconLocation = "$icoPath,0"
    Write-Host "Extracted stable icon to $icoPath" -ForegroundColor Green
} else {
    # Last resort: fall back to the versioned exe (may go blank after an update).
    $iconLocation = "$iconExe,0"
    Write-Warning "Could not extract a standalone icon; falling back to the app exe (icon may break after updates)."
}

# --- Create a profile + desktop shortcut for each name --------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell
$packageAppId = Get-ClaudePackageAppId -Package $pkg
$badgeColors = '#2AABEE', '#34A853', '#8E44AD', '#E53935', '#F9A825', '#00897B'
$badgeIndex = 0

foreach ($name in $Profile) {
    if ($ReuseDefaultForWork -and $name -ieq 'Work') {
        $dataDir = Join-Path $env:APPDATA 'Claude'
        Write-Host "  [$name] reuses existing login at $dataDir"
    } else {
        # IMPORTANT: isolated profiles must live under %APPDATA% (NOT an arbitrary
        # folder such as -InstallDir). Claude Desktop's "Cowork" feature runs its
        # agent inside a Hyper-V VM, and the native VM service resolves the VM image
        # (rootfs.vhdx) at  %APPDATA%\<profile-name>\vm_bundles  -- it ignores the
        # --user-data-dir flag. If the data dir lives elsewhere, Electron provisions
        # the VM under the data dir but the VM service looks under %APPDATA% and dies
        # with "VHDX file not found", so the Cowork workspace never starts. Putting
        # the data dir under %APPDATA% makes both components agree (exactly how the
        # -ReuseDefaultForWork "Work" profile already behaves).
        $dataDir = Join-Path $env:APPDATA $name
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        Write-Host "  [$name] isolated profile at $dataDir"
    }

    $lnkPath = Join-Path $desktop "Claude ($name).lnk"
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    if ($ConfigDir.ContainsKey($name)) {
        $cfg = $ConfigDir[$name]
        New-Item -ItemType Directory -Force -Path $cfg | Out-Null
        $sc.Arguments = '"{0}" "{1}" "{2}"' -f $vbs, $dataDir, $cfg
        Write-Host "      memory/config dir: $cfg"
    } else {
        $sc.Arguments = '"{0}" "{1}"' -f $vbs, $dataDir
    }
    # Isolated profiles get their own taskbar identity (see TaskbarId.ps1) and,
    # unless -NoProfileBadge, an icon with their initial so the pins differ.
    $appId = Get-ClaudeProfileAppId -ProfileDir $dataDir
    $profileIcon = $iconLocation
    if ($appId -and -not $NoProfileBadge -and (Test-Path $icoPath)) {
        $badgePath = Join-Path $binDir "claude-$(Split-Path $dataDir -Leaf).ico"
        $color = $badgeColors[$badgeIndex % $badgeColors.Count]
        $badgeIndex++
        if (New-ProfileIcon -BaseIcoPath $icoPath -IcoPath $badgePath -Letter $name.Substring(0, 1).ToUpper() -Color $color) {
            $profileIcon = "$badgePath,0"
        }
    }
    if (-not $appId) { $appId = $packageAppId }

    $sc.IconLocation = $profileIcon
    $sc.Description = "Claude Desktop - $name profile"
    $sc.WorkingDirectory = $binDir
    $sc.Save()
    if ($appId) {
        try {
            [ClaudeProfiles.Taskbar]::SetShortcutId($lnkPath, $appId)
        } catch {
            Write-Warning "Could not set the taskbar ID on ${lnkPath}: $_"
        }
    }
    Write-Host "  -> created shortcut: $lnkPath" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Done. Open each shortcut and sign in to the matching account." -ForegroundColor Green
Write-Host "Tip: clicking a shortcut again just focuses that profile's window (single instance per profile)."
Write-Host "Tip: right-click a shortcut > Pin to taskbar to give each profile its own taskbar button."

<#
.SYNOPSIS
    Installs "clones" of the Claude Desktop app: one isolated profile + one
    desktop shortcut per account.

.DESCRIPTION
    For each profile name you pass, this script:
      * creates an isolated Chromium data directory under -InstallDir,
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
    Where profile data + launcher scripts live. Default: %USERPROFILE%\ClaudeProfiles.

.PARAMETER ReuseDefaultForWork
    Make the "Work" profile reuse the existing %APPDATA%\Claude login instead of
    a fresh, separate one.

.EXAMPLE
    .\Setup.ps1
    # Creates "Claude (Work)" and "Claude (Personal)" on the Desktop.

.EXAMPLE
    .\Setup.ps1 -Profile Personal,Side,Client -ReuseDefaultForWork
#>
[CmdletBinding()]
param(
    [string[]]$Profile = @('Work', 'Personal'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [switch]$ReuseDefaultForWork
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

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
$vbs = Join-Path $binDir 'launch.vbs'

# --- Create a profile + desktop shortcut for each name --------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell

foreach ($name in $Profile) {
    if ($ReuseDefaultForWork -and $name -ieq 'Work') {
        $dataDir = Join-Path $env:APPDATA 'Claude'
        Write-Host "  [$name] reuses existing login at $dataDir"
    } else {
        $dataDir = Join-Path $InstallDir $name
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        Write-Host "  [$name] isolated profile at $dataDir"
    }

    $lnkPath = Join-Path $desktop "Claude ($name).lnk"
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $sc.Arguments = '"{0}" "{1}"' -f $vbs, $dataDir
    $sc.IconLocation = "$iconExe,0"
    $sc.Description = "Claude Desktop - $name profile"
    $sc.WorkingDirectory = $binDir
    $sc.Save()
    Write-Host "  -> created shortcut: $lnkPath" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Done. Open each shortcut and sign in to the matching account." -ForegroundColor Green
Write-Host "Tip: clicking a shortcut again just focuses that profile's window (single instance per profile)."

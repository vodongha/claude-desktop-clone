<#
.SYNOPSIS
    Launches the Claude Desktop (Windows MSIX) app with an isolated profile.

.DESCRIPTION
    The Claude Desktop app is built on Electron/Chromium, which accepts the
    standard `--user-data-dir` flag. Each distinct data directory gets its own
    Chromium "singleton" lock, so multiple instances — each signed into a
    different account — can run side by side.

    This script resolves the MSIX executable dynamically via Get-AppxPackage so
    it keeps working after the app updates (the WindowsApps path contains a
    version number that changes on every update).

.PARAMETER ProfileDir
    Absolute path to the data directory for this instance. A fresh directory =
    a fresh, isolated login. Point it at "$env:APPDATA\Claude" to reuse the
    account that the normally-installed app is already signed into.

.EXAMPLE
    .\Launch-Claude.ps1 -ProfileDir "$env:USERPROFILE\ClaudeProfiles\personal"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileDir,

    # Optional: give this instance its own Claude Code / Cowork config + memory
    # store by pointing CLAUDE_CONFIG_DIR at a dedicated directory. Useful to
    # keep a personal profile's memory separate from a work one.
    [string]$ConfigDir
)

function Show-Error {
    param([string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Message, 'claude-desktop-clone', 'OK', 'Error') | Out-Null
    } catch {
        Write-Error $Message
    }
}

# 1) Preferred: resolve via the Appx package (robust against version changes).
$exe = $null
try {
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction Stop |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $candidate = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (Test-Path $candidate) { $exe = $candidate }
    }
} catch { }

# 2) Fallback: scan WindowsApps directly (newest version first).
if (-not $exe) {
    $exe = Get-ChildItem 'C:\Program Files\WindowsApps\Claude_*__*\app\Claude.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

if (-not $exe -or -not (Test-Path $exe)) {
    Show-Error "Claude Desktop app was not found.`n`nInstall it from the Microsoft Store / claude.ai/download first, then run again."
    exit 1
}

# Ensure the isolated data directory exists.
New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null

# Optionally isolate Claude Code / Cowork config + memory for this instance.
# Start-Process inherits this process's environment, so the launched app (and
# any claude-code it spawns) picks up CLAUDE_CONFIG_DIR.
if ($ConfigDir) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
}

# Launch. Different --user-data-dir => separate singleton lock => parallel instance.
Start-Process -FilePath $exe -ArgumentList "--user-data-dir=$ProfileDir"

# Give non-default profiles their own taskbar button, so each one can be
# pinned separately (see TaskbarId.ps1). This process stays behind, hidden, as
# the window watcher until the instance exits; launching the same profile
# again while it runs just returns.
$taskbarHelper = Join-Path $PSScriptRoot 'TaskbarId.ps1'
if (Test-Path $taskbarHelper) {
    . $taskbarHelper
    $appId = Get-ClaudeProfileAppId -ProfileDir $ProfileDir
    if ($appId) {
        $profileName = Split-Path $ProfileDir.TrimEnd('\') -Leaf
        $icon = Join-Path $PSScriptRoot "claude-$profileName.ico"
        if (-not (Test-Path $icon)) { $icon = Join-Path $PSScriptRoot 'claude.ico' }
        $relaunch = '"{0}" "{1}" "{2}"' -f (Join-Path $env:WINDIR 'System32\wscript.exe'), (Join-Path $PSScriptRoot 'launch.vbs'), $ProfileDir
        if ($ConfigDir) { $relaunch += ' "{0}"' -f $ConfigDir }
        Watch-ClaudeWindows -ProfileDir $ProfileDir -AppId $appId -RelaunchCommand $relaunch `
            -DisplayName "Claude ($profileName)" -IconFile $icon
    }
}

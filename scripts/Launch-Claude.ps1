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
$packageFamily = $null
try {
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction Stop |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $candidate = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (Test-Path $candidate) { $exe = $candidate }
        $packageFamily = $pkg.PackageFamilyName
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

# Package family = "<Name>_<PublisherHash>", e.g. Claude_pzs8sxrjxfjjc. Derive it
# from the install folder (Claude_<version>_x64__<hash>) if the Appx query failed.
if (-not $packageFamily -and $exe -match '\\(Claude)_[^\\]*__([a-z0-9]+)\\app\\') {
    $packageFamily = "$($Matches[1])_$($Matches[2])"
}

$ProfileDir = [IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
$appData = [IO.Path]::GetFullPath($env:APPDATA).TrimEnd('\')
$defaultDir = Join-Path $appData 'Claude'
$isDefault = $ProfileDir -ieq $defaultDir -or
    $ProfileDir -like (Join-Path $env:LOCALAPPDATA 'Claude-Data\*')

# Isolated profiles must sit directly under %APPDATA%: the app only honours
# --user-data-dir there (see the user-data-move note below), and the Cowork VM
# service resolves %APPDATA%\<name>\vm_bundles.
if (-not $isDefault -and (Split-Path -Parent $ProfileDir) -ine $appData) {
    Show-Error "Profile folder must be directly under %APPDATA% (e.g. $appData\Personal).`n`nGot: $ProfileDir`n`nRe-run Setup.ps1 to recreate the shortcut."
    exit 1
}

# Ensure the isolated data directory exists.
New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null

# Keep the app from merging this profile into the shared default one.
# Since 2.42304 the MSIX app moves its userData out of the package to
# %LOCALAPPDATA%\Claude-Data\<packagefamily> on startup. That target is FIXED
# per package -- it ignores --user-data-dir -- so once the default profile has
# moved, every other --user-data-dir under %APPDATA% gets redirected into the
# same folder (and same single-instance lock): all shortcuts open one account.
# The app's own "moved back" marker in the profile's package-cache copy
# (%LOCALAPPDATA%\Packages\<pfn>\LocalCache\Roaming\<name>) tells it to keep
# using the profile in place, so set it before every launch (idempotent).
if (-not $isDefault -and $packageFamily) {
    $pfn = $packageFamily.ToLowerInvariant()
    $packageCopy = Join-Path $env:LOCALAPPDATA "Packages\$packageFamily\LocalCache\Roaming\$(Split-Path -Leaf $ProfileDir)"
    try {
        New-Item -ItemType Directory -Force -Path $packageCopy | Out-Null
        $back = Join-Path $packageCopy ".user-data-back.$pfn"
        if (-not (Test-Path -LiteralPath $back)) { New-Item -ItemType File -Path $back | Out-Null }
        foreach ($dir in $packageCopy, $ProfileDir) {
            Remove-Item -LiteralPath (Join-Path $dir ".user-data-left.$pfn") -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Could not write the user-data marker in ${packageCopy}: $_"
    }
}

# Optionally isolate Claude Code / Cowork config + memory for this instance.
# Start-Process inherits this process's environment, so the launched app (and
# any claude-code it spawns) picks up CLAUDE_CONFIG_DIR.
if ($ConfigDir) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
}

# Launch. Different --user-data-dir => separate singleton lock => parallel instance.
Start-Process -FilePath $exe -ArgumentList "--user-data-dir=$ProfileDir"
